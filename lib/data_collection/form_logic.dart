// Client-side copy of the CRM's form rules, so the officer sees problems
// while still with the respondent instead of after sync. Mirrors
// App\Support\DataCollection\ConditionEvaluator and SubmissionValidationService
// — the server re-checks everything, this only has to agree with it.

const numberTypes = {'number', 'decimal', 'integer'};

bool isEmptyAnswer(dynamic v) => v == null || v == '' || (v is List && v.isEmpty);

List<Map<String, dynamic>> sectionsOf(Map<String, dynamic> schema) =>
    ((schema['sections'] as List?) ?? const []).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> questionsOf(Map<String, dynamic> section) =>
    ((section['questions'] as List?) ?? const []).cast<Map<String, dynamic>>();

// PHP's (string) cast, which ConditionEvaluator::loose compares with.
String _phpString(dynamic v) {
  if (v == null) return '';
  if (v is bool) return v ? '1' : '';
  if (v is double && v == v.truncateToDouble()) return v.toInt().toString();
  return v.toString();
}

num? _numeric(dynamic v) => v is num ? v : (v is String ? num.tryParse(v.trim()) : null);

bool isVisible(Map<String, dynamic> question, Map<String, dynamic> answers) {
  final condition = question['visible_if'];
  if (condition is! Map) return true;

  final target = answers[condition['question'] ?? ''];
  final value = condition['value'];
  final a = _numeric(target);
  final b = _numeric(value);

  switch (condition['operator'] ?? 'equals') {
    case 'equals':
      return _phpString(target) == _phpString(value);
    case 'not_equals':
      return _phpString(target) != _phpString(value);
    case 'greater_than':
      return a != null && b != null && a > b;
    case 'less_than':
      return a != null && b != null && a < b;
    case 'greater_than_or_equal':
      return a != null && b != null && a >= b;
    case 'less_than_or_equal':
      return a != null && b != null && a <= b;
    case 'contains':
      return target is List ? target.contains(value) : _phpString(target).contains(_phpString(value));
    case 'is_empty':
      return isEmptyAnswer(target);
    case 'is_not_empty':
      return !isEmptyAnswer(target);
    default:
      return true;
  }
}

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

// Question id → message, empty when the submission can be finalized.
Map<String, String> validateAnswers(Map<String, dynamic> schema, Map<String, dynamic> answers) {
  final errors = <String, String>{};

  for (final section in sectionsOf(schema)) {
    for (final q in questionsOf(section)) {
      // Hidden by skip logic — the officer never had a chance to answer it.
      if (!isVisible(q, answers)) continue;

      final id = q['id'] as String;
      final value = answers[id];

      if (q['required'] == true && isEmptyAnswer(value)) {
        errors[id] = 'This question is required.';
        continue;
      }
      if (isEmptyAnswer(value)) continue;

      final type = q['type'];
      if (numberTypes.contains(type) && _numeric(value) == null) {
        errors[id] = 'Must be a number.';
      } else if (type == 'integer' && _numeric(value) is! int) {
        errors[id] = 'Must be a whole number.';
      } else if (type == 'email' && !_emailPattern.hasMatch(value.toString())) {
        errors[id] = 'Must be a valid email address.';
      }
    }
  }
  return errors;
}

// Answers to questions hidden by skip logic are dropped on finalize, like
// Kobo does, so the CRM doesn't store answers to questions that weren't asked.
Map<String, dynamic> visibleAnswersOnly(Map<String, dynamic> schema, Map<String, dynamic> answers) {
  final result = Map<String, dynamic>.of(answers);
  for (final section in sectionsOf(schema)) {
    for (final q in questionsOf(section)) {
      if (!isVisible(q, answers)) result.remove(q['id']);
    }
  }
  return result;
}
