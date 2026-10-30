import 'package:flutter_test/flutter_test.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/form_logic.dart';

void main() {
  final schema = {
    'sections': [
      {
        'id': 's1',
        'title': 'Basics',
        'questions': [
          {'id': 'age', 'type': 'integer', 'label': 'Age', 'required': true},
          {'id': 'in_school', 'type': 'yes_no', 'label': 'In school?'},
          {
            'id': 'school_name',
            'type': 'text',
            'label': 'School',
            'required': true,
            'visible_if': {'question': 'in_school', 'operator': 'equals', 'value': 'yes'},
          },
          {
            'id': 'adult_q',
            'type': 'text',
            'label': 'Adult only',
            'visible_if': {'question': 'age', 'operator': 'greater_than_or_equal', 'value': 18},
          },
          {'id': 'email', 'type': 'email', 'label': 'Email'},
        ],
      },
    ],
  };
  Map<String, dynamic> q(String id) =>
      sectionsOf(schema).expand(questionsOf).firstWhere((x) => x['id'] == id);

  test('visible_if follows earlier answers', () {
    expect(isVisible(q('school_name'), {'in_school': 'no'}), isFalse);
    expect(isVisible(q('school_name'), {'in_school': 'yes'}), isTrue);
    expect(isVisible(q('adult_q'), {'age': 17}), isFalse);
    expect(isVisible(q('adult_q'), {'age': 18}), isTrue);
    expect(isVisible(q('adult_q'), {}), isFalse);
  });

  test('required only applies to visible questions', () {
    expect(validateAnswers(schema, {'age': 20, 'in_school': 'no'}), isEmpty);
    expect(validateAnswers(schema, {'age': 20, 'in_school': 'yes'}).keys, ['school_name']);
    expect(validateAnswers(schema, {}).keys, ['age']);
  });

  test('type checks', () {
    expect(validateAnswers(schema, {'age': 'abc'})['age'], 'Must be a number.');
    expect(validateAnswers(schema, {'age': 20, 'email': 'nope'}).keys, ['email']);
  });

  test('hidden answers are dropped on finalize', () {
    final answers = {'age': 20, 'in_school': 'no', 'school_name': 'Old answer'};
    expect(visibleAnswersOnly(schema, answers).containsKey('school_name'), isFalse);
  });
}
