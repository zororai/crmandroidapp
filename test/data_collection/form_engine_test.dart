import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/engine/form_engine.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/expression/evaluator.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/models/form_schema.dart';

FormSchema loadSample() => FormSchema.fromJson(
      jsonDecode(File('assets/data_collection/household_survey.json').readAsStringSync()) as Map<String, dynamic>,
    );

const _root = <RepeatFrame>[];

void main() {
  final evaluator = ExpressionEvaluator(now: () => DateTime(2026, 10, 30));
  FormEngine newEngine() => FormEngine(loadSample(), evaluator: evaluator);
  Set<String> visibleKeys(FormEngine e) => e.renderItems().map((i) => fieldKey(i.frames, i.node.name)).toSet();
  Set<String> issueKeys(FormEngine e) => e.validate().map((i) => i.key).toSet();

  group('schema parsing', () {
    test('flat begin/end rows nest into groups and repeats with choice lists', () {
      final schema = loadSample();
      final household = schema.children.firstWhere((n) => n.name == 'household');
      expect(household.isGroup, isTrue);
      expect(household.children.map((n) => n.name), contains('district'));
      expect(household.children.firstWhere((n) => n.name == 'district').choices.length, 5);

      final members = schema.children.firstWhere((n) => n.name == 'members');
      expect(members.isRepeat, isTrue);
      expect(members.children.first.required, 'true()');
    });

    test('nested pyxform-style JSON with bind and inline choices', () {
      final schema = FormSchema.fromJson({
        'title': 'Nested',
        'version': '1',
        'children': [
          {
            'type': 'group',
            'name': 'g',
            'label': {'English (en)': 'Group'},
            'children': [
              {
                'type': 'select one',
                'name': 'q',
                'label': 'Q',
                'bind': {'required': 'yes', 'relevant': "\${x} = 'a'", 'jr:constraintMsg': 'Bad'},
                'children': [
                  {'name': 'a', 'label': 'A'},
                ],
              },
            ],
          },
          {'type': 'start', 'name': 'start'},
          {'type': 'barcode', 'name': 'code', 'label': 'Scan'},
        ],
      });
      final q = schema.children.first.children.single;
      expect(schema.children.first.label, 'Group');
      expect(q.type, 'select_one');
      expect(q.required, 'true()');
      expect(q.relevant, "\${x} = 'a'");
      expect(q.constraintMessage, 'Bad');
      expect(q.choices.single.name, 'a');
      expect(schema.children.map((n) => n.name), isNot(contains('start')), reason: 'metadata types are skipped');
      expect(schema.children.last.type, 'unsupported');
    });
  });

  group('skip logic', () {
    test('household questions only appear after consent', () {
      final e = newEngine();
      expect(visibleKeys(e), isNot(contains('head_name')));
      e.setValue(_root, 'consent', 'yes');
      expect(visibleKeys(e), contains('head_name'));
      e.setValue(_root, 'consent', 'no');
      expect(visibleKeys(e), containsAll(['no_consent']));
      expect(visibleKeys(e), isNot(contains('head_name')));
    });

    test('"other" district asks which one', () {
      final e = newEngine()..setValue(_root, 'consent', 'yes');
      expect(visibleKeys(e), isNot(contains('district_other')));
      e.setValue(_root, 'district', 'other');
      expect(visibleKeys(e), contains('district_other'));
    });

    test('hidden answers are excluded from the payload', () {
      final e = newEngine()
        ..setValue(_root, 'consent', 'yes')
        ..setValue(_root, 'district', 'other')
        ..setValue(_root, 'district_other', 'Masvingo')
        ..setValue(_root, 'district', 'harare');
      expect(e.data['district_other'], 'Masvingo', reason: 'kept while editing in case they switch back');
      expect(e.payload().containsKey('district_other'), isFalse);
    });

    test('everything after a refused consent is excluded', () {
      final e = newEngine()
        ..setValue(_root, 'consent', 'yes')
        ..setValue(_root, 'head_name', 'Rudo')
        ..setValue(_root, 'consent', 'no');
      expect(e.payload().keys, unorderedEquals(['consent']));
    });
  });

  group('defaults, required and constraints', () {
    test('default today() is applied to a new submission', () {
      expect(newEngine().data['interview_date'], '2026-10-30');
    });

    test('required questions only count when visible', () {
      final e = newEngine();
      expect(issueKeys(e), {'consent'});
      e.setValue(_root, 'consent', 'no');
      expect(issueKeys(e), isEmpty);
      e.setValue(_root, 'consent', 'yes');
      expect(issueKeys(e), containsAll(['head_name', 'district']));
    });

    test('constraint with . and a custom message', () {
      final e = newEngine()..setValue(_root, 'consent', 'yes');
      e.setValue(_root, 'interview_date', '2026-11-05');
      final issue = e.validate().firstWhere((i) => i.node.name == 'interview_date');
      expect(issue.message, "The interview date can't be in the future.");
    });

    test('select_multiple constraint: "none" with other sources', () {
      final e = newEngine()..setValue(_root, 'consent', 'yes');
      e.setValue(_root, 'income_sources', 'farming none');
      expect(issueKeys(e), contains('income_sources'));
      e.setValue(_root, 'income_sources', 'none');
      expect(issueKeys(e), isNot(contains('income_sources')));
    });

    test('integer type check', () {
      final e = newEngine()..setValue(_root, 'consent', 'yes');
      e.addRepeatInstance(_root, e.node('members')!);
      e.setValue(const [RepeatFrame('members', 0)], 'member_age', '12.5');
      expect(e.validate().firstWhere((i) => i.node.name == 'member_age').message, 'Enter a whole number.');
    });
  });

  group('repeats and calculations', () {
    FormEngine withMembers(List<(String, int)> members) {
      final e = newEngine()..setValue(_root, 'consent', 'yes');
      for (final (name, age) in members) {
        e.addRepeatInstance(_root, e.node('members')!);
        final frames = [RepeatFrame('members', e.instanceCount(_root, 'members') - 1)];
        e.setValue(frames, 'member_name', name);
        e.setValue(frames, 'member_age', age);
      }
      return e;
    }

    test('relevance inside a repeat uses that instance', () {
      final e = withMembers([('Tari', 10), ('Nyasha', 40)]);
      final keys = visibleKeys(e);
      expect(keys, contains('members[0]/in_school'));
      expect(keys, isNot(contains('members[1]/in_school')));
    });

    test('per-instance calculation and aggregates across instances', () {
      final e = withMembers([('Tari', 10), ('Nyasha', 40), ('Farai', 19)]);
      expect(e.valueOf(const [RepeatFrame('members', 1)], 'is_adult'), 1);
      expect(e.data['member_count'], 3);
      expect(e.data['adult_count'], 2);
    });

    test('calculation that depends on a later answer', () {
      final e = withMembers([('Tari', 10), ('Nyasha', 40)])
        ..setValue(_root, 'income_sources', 'farming')
        ..setValue(_root, 'monthly_income', 250);
      expect(e.data['income_per_member'], 125);
    });

    test('removing an instance updates counts', () {
      final e = withMembers([('Tari', 10), ('Nyasha', 40)]);
      e.removeRepeatInstance(_root, 'members', 0);
      expect(e.data['member_count'], 1);
      expect(e.valueOf(const [RepeatFrame('members', 0)], 'member_name'), 'Nyasha');
    });

    test('label interpolation inside a repeat', () {
      final e = withMembers([('Tari', 10)]);
      expect(e.interpolate('Is \${member_name} attending school?', const [RepeatFrame('members', 0)]), 'Is Tari attending school?');
    });

    test('payload keeps repeats as lists and drops hidden fields per instance', () {
      final e = withMembers([('Tari', 10), ('Nyasha', 40)]);
      e.setValue(const [RepeatFrame('members', 1)], 'in_school', 'yes'); // hidden for a 40-year-old
      final members = e.payload()['members'] as List;
      expect(members.length, 2);
      expect((members[1] as Map).containsKey('in_school'), isFalse);
    });

    test('required inside a repeat is reported per instance', () {
      final e = newEngine()..setValue(_root, 'consent', 'yes');
      e.addRepeatInstance(_root, e.node('members')!);
      expect(issueKeys(e), containsAll(['members[0]/member_name', 'members[0]/member_age', 'members[0]/member_sex']));
    });
  });

  test('progress counts only visible, askable questions', () {
    final e = newEngine();
    expect(e.progress(), (0, 1));
    e.setValue(_root, 'consent', 'no');
    expect(e.progress(), (1, 1));
  });

  test('bad expressions are collected, not thrown', () {
    final schema = FormSchema.fromJson({
      'survey': [
        {'type': 'text', 'name': 'a', 'label': 'A', 'relevant': 'broken('},
      ],
    });
    final e = FormEngine(schema);
    expect(e.renderItems().length, 1, reason: 'falls back to showing the question');
    expect(e.expressionErrors, isNotEmpty);
  });
}
