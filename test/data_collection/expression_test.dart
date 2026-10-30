import 'package:flutter_test/flutter_test.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/expression/evaluator.dart';

class _MapScope implements EvalScope {
  _MapScope(this.values, {this.current, this.position = 0});

  final Map<String, dynamic> values;
  @override
  final dynamic current;
  @override
  final int position;

  @override
  dynamic resolve(String name) => values[name] ?? '';
}

void main() {
  final evaluator = ExpressionEvaluator(now: () => DateTime(2026, 10, 30, 14, 5));
  dynamic eval(String expr, [Map<String, dynamic> values = const {}, dynamic current]) =>
      evaluator.evaluate(expr, _MapScope(values, current: current, position: 2));
  bool check(String expr, [Map<String, dynamic> values = const {}, dynamic current]) =>
      evaluator.evaluateBool(expr, _MapScope(values, current: current));

  group('comparison and logic', () {
    test('string and number equality', () {
      expect(check("\${a} = 'yes'", {'a': 'yes'}), isTrue);
      expect(check("\${a} != 'yes'", {'a': 'no'}), isTrue);
      expect(check('\${age} = 18', {'age': 18}), isTrue);
      expect(check("\${age} = '18'", {'age': 18}), isTrue, reason: 'number vs numeric string compares as numbers');
    });

    test('relational on numbers, empty is never greater or less', () {
      expect(check('\${age} >= 18', {'age': 20}), isTrue);
      expect(check('\${age} < 5', {'age': 20}), isFalse);
      expect(check('\${age} > 18', {}), isFalse);
      expect(check('\${age} < 18', {}), isFalse);
    });

    test('and / or / not precedence', () {
      expect(check("\${a} = 1 or \${b} = 1 and \${c} = 1", {'a': 1, 'b': 0, 'c': 0}), isTrue);
      expect(check("(\${a} = 1 or \${b} = 1) and \${c} = 1", {'a': 1, 'b': 0, 'c': 0}), isFalse);
      expect(check("not(\${a} = 'x')", {'a': 'y'}), isTrue);
    });

    test('dates compare and subtract as days', () {
      expect(check("\${d} <= today()", {'d': '2026-10-30'}), isTrue);
      expect(check("\${d} <= today()", {'d': '2026-10-31'}), isFalse);
      expect(eval("today() - \${dob}", {'dob': '2026-10-20'}), 10);
      expect(eval("int((today() - \${dob}) div 365.25)", {'dob': '2000-04-15'}), 26);
    });

    test('time strings compare as strings', () {
      expect(check("\${t} > '08:00'", {'t': '09:30'}), isTrue);
    });
  });

  group('arithmetic', () {
    test('operators and precedence', () {
      expect(eval('1 + 2 * 3'), 7);
      expect(eval('(1 + 2) * 3'), 9);
      expect(eval('7 div 2'), 3.5);
      expect(eval('7 mod 3'), 1);
      expect(eval('-\${x} + 1', {'x': 4}), -3);
    });

    test('empty operands give NaN, stored as empty', () {
      expect(xString(eval('\${x} + 1')), '');
    });
  });

  group('functions', () {
    test('selected and count-selected on space-separated answers', () {
      expect(check("selected(\${s}, 'b')", {'s': 'a b c'}), isTrue);
      expect(check("selected(\${s}, 'd')", {'s': 'a b c'}), isFalse);
      expect(eval('count-selected(\${s})', {'s': 'a b c'}), 3);
      expect(eval('count-selected(\${s})', {}), 0);
    });

    test('if only evaluates the taken branch', () {
      expect(eval("if(\${a} > 1, 'big', 'small')", {'a': 5}), 'big');
      expect(eval("if(true(), 'ok', unknown-fn())"), 'ok');
    });

    test('string functions', () {
      expect(eval("concat(\${a}, ' ', \${b})", {'a': 'Tendai', 'b': 'Moyo'}), 'Tendai Moyo');
      expect(eval('string-length(\${a})', {'a': 'abcd'}), 4);
      expect(eval("substr('abcdef', 1, 3)"), 'bc');
      expect(check("contains(\${a}, 'ell')", {'a': 'hello'}), isTrue);
      expect(check("starts-with(\${a}, 'he')", {'a': 'hello'}), isTrue);
      expect(check("regex(\${p}, '^07[0-9]{8}\$')", {'p': '0771234567'}), isTrue);
      expect(check("regex(\${p}, '^07[0-9]{8}\$')", {'p': '12345'}), isFalse);
    });

    test('today, now, rounding, coalesce', () {
      expect(eval('today()'), '2026-10-30');
      expect(eval('now()'), '2026-10-30T14:05:00');
      expect(eval('round(2.345, 2)'), 2.35);
      expect(eval("coalesce(\${a}, 'fallback')"), 'fallback');
    });

    test('lists from repeats: count, sum, max', () {
      final v = {'ages': [10, 20, 30]};
      expect(eval('count(\${ages})', v), 3);
      expect(eval('sum(\${ages})', v), 60);
      expect(eval('max(\${ages})', v), 30);
      expect(check('\${ages} > 25', v), isTrue, reason: 'list comparison: any item matches');
    });

    test('current value and position', () {
      expect(check('. >= 0 and . <= 120', {}, 45), isTrue);
      expect(check('. >= 0 and . <= 120', {}, 130), isFalse);
      expect(eval('position(..)'), 2);
    });
  });

  group('errors', () {
    test('syntax errors are reported, not crashes', () {
      expect(() => eval(r'${a = 1'), throwsA(isA<ExpressionError>()));
      expect(() => eval('1 +'), throwsA(isA<ExpressionError>()));
      expect(() => eval('age > 1'), throwsA(isA<ExpressionError>()), reason: 'bare names must be \${…}');
      expect(() => eval('nope(1)'), throwsA(isA<ExpressionError>()));
    });
  });
}
