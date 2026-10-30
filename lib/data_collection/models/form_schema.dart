// The form definition served by GET /api/v1/forms/{id}/schema.
//
// Two shapes are accepted, so either works for the CRM side:
//  - nested: group/repeat nodes carry their questions in `children`
//    (pyxform's JSON output), with `bind` holding relevant/constraint/etc.;
//  - flat: XLSForm survey rows with begin_group … end_group markers.
// Choices can be inline on the question or a top-level `choices` map/list
// referenced by list name ("select_one yes_no").

class FormChoice {
  const FormChoice(this.name, this.label);

  final String name;
  final String label;
}

class FormNode {
  FormNode({
    required this.type,
    required this.name,
    this.label = '',
    this.hint,
    this.required,
    this.requiredMessage,
    this.relevant,
    this.constraint,
    this.constraintMessage,
    this.defaultValue,
    this.calculation,
    this.appearance,
    this.readOnly = false,
    this.choices = const [],
    this.children = const [],
    this.sourceType,
  });

  final String type; // one of supportedQuestionTypes, or 'unsupported'
  final String name;
  final String label;
  final String? hint;
  final String? required; // expression; null when optional
  final String? requiredMessage;
  final String? relevant;
  final String? constraint;
  final String? constraintMessage;
  final String? defaultValue;
  final String? calculation;
  final String? appearance;
  final bool readOnly;
  final List<FormChoice> choices;
  final List<FormNode> children;
  final String? sourceType; // the type as written in the schema, for 'unsupported'

  bool get isGroup => type == 'group';
  bool get isRepeat => type == 'repeat';
  bool get isContainer => isGroup || isRepeat;

  // Holds an answer in the submission data.
  bool get hasValue => !isContainer && type != 'note' && type != 'unsupported';

  // Shown to the enumerator as something to answer.
  bool get isAskable => hasValue && type != 'calculate' && !readOnly;
}

class FormSchema {
  FormSchema({required this.formId, required this.title, required this.version, required this.children});

  final int? formId;
  final String title;
  final String version;
  final List<FormNode> children;

  factory FormSchema.fromJson(Map<String, dynamic> json) {
    final lists = _parseChoiceLists(json['choices']);
    final rows = (json['survey'] ?? json['children'] ?? json['questions'] ?? const []) as List;
    final settings = json['settings'] is Map ? json['settings'] as Map : const {};

    return FormSchema(
      formId: _int(json['form_id'] ?? json['id']),
      title: labelText(json['title'] ?? settings['form_title'] ?? json['name'] ?? ''),
      version: '${json['version'] ?? settings['version'] ?? ''}',
      children: _buildNodes(rows, lists),
    );
  }
}

const supportedQuestionTypes = {
  'text', 'integer', 'decimal', 'select_one', 'select_multiple', 'date', 'time',
  'datetime', 'geopoint', 'photo', 'note', 'calculate', 'group', 'repeat',
};

// XLSForm metadata types the device doesn't ask about — dropped silently.
const _metadataTypes = {
  'start', 'end', 'today', 'deviceid', 'phonenumber', 'username', 'email',
  'audit', 'simserial', 'subscriberid', 'start-geopoint',
};

// Multi-language labels come as {"English (en)": "...", "Shona (sn)": "..."}.
String labelText(dynamic label) {
  if (label == null) return '';
  if (label is Map) {
    if (label['default'] != null) return '${label['default']}';
    for (final entry in label.entries) {
      if ('${entry.key}'.toLowerCase().startsWith('english')) return '${entry.value}';
    }
    return label.isEmpty ? '' : '${label.values.first}';
  }
  return '$label';
}

int? _int(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}');

// Returns (normalized type, choice list name from "select_one list").
(String, String?) _normalizeType(String raw) {
  final lower = raw.trim().toLowerCase();
  if (lower == 'select one' || lower == 'select1') return ('select_one', null);
  if (lower == 'select all that apply' || lower == 'select multiple') return ('select_multiple', null);

  final parts = lower.replaceFirstMapped(RegExp(r'^(begin|end) '), (m) => '${m[1]}_').split(RegExp(r'\s+'));
  final listName = parts.length > 1 ? raw.trim().split(RegExp(r'\s+'))[1] : null;
  final type = switch (parts.first) {
    'begin_group' => 'group',
    'begin_repeat' => 'repeat',
    'string' => 'text',
    'int' => 'integer',
    'image' => 'photo',
    'select1' => 'select_one',
    final t => t,
  };
  return (type, listName);
}

String? _str(dynamic v) {
  if (v == null) return null;
  final s = labelText(v).trim();
  return s.isEmpty ? null : s;
}

// `required` may be yes/no/true/false or an expression.
String? _requiredExpr(dynamic v) {
  if (v == null || v == false) return null;
  if (v == true) return 'true()';
  final s = '$v'.trim();
  return switch (s.toLowerCase()) {
    '' || 'no' || 'false' || 'false()' => null,
    'yes' || 'true' || 'true()' => 'true()',
    _ => s,
  };
}

bool _truthy(dynamic v) => v == true || ['yes', 'true', 'true()'].contains('$v'.trim().toLowerCase());

Map<String, List<FormChoice>> _parseChoiceLists(dynamic raw) {
  final lists = <String, List<FormChoice>>{};
  if (raw is Map) {
    raw.forEach((name, items) {
      if (items is List) lists['$name'] = items.whereType<Map>().map(_choice).toList();
    });
  } else if (raw is List) {
    for (final row in raw.whereType<Map>()) {
      lists.putIfAbsent('${row['list_name']}', () => []).add(_choice(row));
    }
  }
  return lists;
}

FormChoice _choice(Map c) => FormChoice('${c['name'] ?? c['value']}', labelText(c['label'] ?? c['name'] ?? c['value']));

class _OpenContainer {
  _OpenContainer(this.row, this.type);

  final Map row;
  final String type;
  final children = <FormNode>[];
}

List<FormNode> _buildNodes(List rows, Map<String, List<FormChoice>> lists) {
  final root = <FormNode>[];
  final stack = <_OpenContainer>[];
  List<FormNode> current() => stack.isEmpty ? root : stack.last.children;

  for (final row in rows.whereType<Map>()) {
    final (type, listName) = _normalizeType('${row['type'] ?? ''}');

    if (type == 'end_group' || type == 'end_repeat') {
      if (stack.isNotEmpty) {
        final open = stack.removeLast();
        current().add(_node(open.row, open.type, null, lists, open.children));
      }
      continue;
    }
    if (_metadataTypes.contains(type) || (type == 'group' && row['name'] == 'meta')) continue;

    final isContainer = type == 'group' || type == 'repeat';
    if (isContainer && row['children'] == null) {
      stack.add(_OpenContainer(row, type));
      continue;
    }
    final kids = isContainer ? _buildNodes(row['children'] as List, lists) : const <FormNode>[];
    current().add(_node(row, type, listName, lists, kids));
  }

  // Tolerate a missing end_group at the end of the sheet.
  while (stack.isNotEmpty) {
    final open = stack.removeLast();
    current().add(_node(open.row, open.type, null, lists, open.children));
  }
  return root;
}

FormNode _node(Map row, String type, String? listName, Map<String, List<FormChoice>> lists, List<FormNode> children) {
  final bind = row['bind'] is Map ? row['bind'] as Map : const {};
  final control = row['control'] is Map ? row['control'] as Map : const {};
  dynamic pick(String key, [String? bindKey]) => row[key] ?? bind[bindKey ?? key];

  var choices = const <FormChoice>[];
  if (type == 'select_one' || type == 'select_multiple') {
    final inline = row['choices'];
    if (inline is List) {
      choices = inline.whereType<Map>().map(_choice).toList();
    } else if (row['children'] is List) {
      choices = (row['children'] as List).whereType<Map>().map(_choice).toList(); // pyxform JSON
    } else {
      final ref = inline is String ? inline : (listName ?? row['list_name'] ?? row['itemset']);
      choices = lists['$ref'] ?? const [];
    }
  }

  final supported = supportedQuestionTypes.contains(type);
  return FormNode(
    type: supported ? type : 'unsupported',
    sourceType: '${row['type'] ?? ''}',
    name: '${row['name'] ?? ''}',
    label: labelText(row['label']),
    hint: _str(row['hint']),
    required: _requiredExpr(pick('required')),
    requiredMessage: _str(pick('required_message', 'jr:requiredMsg')),
    relevant: _str(pick('relevant')),
    constraint: _str(pick('constraint')),
    constraintMessage: _str(pick('constraint_message', 'jr:constraintMsg')),
    defaultValue: _str(row['default']),
    calculation: _str(pick('calculation', 'calculate')),
    appearance: _str(row['appearance'] ?? control['appearance']),
    readOnly: _truthy(pick('read_only', 'readonly')),
    choices: choices,
    children: (type == 'group' || type == 'repeat') ? children : const [],
  );
}
