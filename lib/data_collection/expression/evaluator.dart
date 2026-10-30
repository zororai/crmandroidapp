import 'dart:math' as math;
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'parser.dart';

export 'parser.dart' show ExpressionError;

// What an expression can see: question values (scalars, or lists when the
// question sits in a repeat and is referenced from outside it), the current
// value for '.', and the repeat position for position(..).
abstract class EvalScope {
  dynamic resolve(String name);
  dynamic get current;
  int get position;
}

// Values follow XPath typing: String, double, bool, or List (a nodeset).
// Unanswered questions are ''. Dates ('yyyy-MM-dd…') convert to numbers as
// days since 1970, so today() - ${dob} and ${a} < ${b} work on dates.
class ExpressionEvaluator {
  ExpressionEvaluator({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _cache = <String, Expr>{};

  Expr parse(String source) => _cache.putIfAbsent(source, () => ExpressionParser(source).parse());

  dynamic evaluate(String source, EvalScope scope) => _eval(parse(source), scope);

  bool evaluateBool(String source, EvalScope scope) => xBool(evaluate(source, scope));

  dynamic _eval(Expr e, EvalScope s) => switch (e) {
        LiteralExpr(:final value) => value,
        RefExpr(:final name) => s.resolve(name),
        CurrentExpr() => s.current ?? '',
        ParentExpr() => '',
        NegateExpr(:final operand) => -xNumber(_eval(operand, s)),
        CallExpr() => _call(e, s),
        BinaryExpr() => _binary(e, s),
      };

  dynamic _binary(BinaryExpr e, EvalScope s) {
    if (e.op == 'or') return xBool(_eval(e.left, s)) || xBool(_eval(e.right, s));
    if (e.op == 'and') return xBool(_eval(e.left, s)) && xBool(_eval(e.right, s));

    final a = _eval(e.left, s);
    final b = _eval(e.right, s);
    switch (e.op) {
      case '=':
        return _equals(a, b);
      case '!=':
        return !_equals(a, b);
      case '<' || '<=' || '>' || '>=':
        return _compare(a, b, e.op);
    }

    final x = xNumber(a);
    final y = xNumber(b);
    return switch (e.op) {
      '+' => x + y,
      '-' => x - y,
      '*' => x * y,
      'div' => x / y,
      'mod' => x.remainder(y),
      _ => throw ExpressionError('Unknown operator ${e.op}.'),
    };
  }

  bool _equals(dynamic a, dynamic b) {
    if (a is List) return a.any((x) => _equals(x, b));
    if (b is List) return b.any((y) => _equals(a, y));
    if (a is bool || b is bool) return xBool(a) == xBool(b);
    if (a is num || b is num) return xNumber(a) == xNumber(b);
    return xString(a) == xString(b);
  }

  bool _compare(dynamic a, dynamic b, String op) {
    if (a is List) return a.any((x) => _compare(x, b, op));
    if (b is List) return b.any((y) => _compare(a, y, op));

    final x = xNumber(a);
    final y = xNumber(b);
    int? order;
    if (!x.isNaN && !y.isNaN) {
      order = x.compareTo(y);
    } else if (a is String && b is String && a.isNotEmpty && b.isNotEmpty) {
      order = a.compareTo(b); // e.g. 'HH:mm' times
    }
    if (order == null) return false;
    return switch (op) { '<' => order < 0, '<=' => order <= 0, '>' => order > 0, _ => order >= 0 };
  }

  dynamic _call(CallExpr e, EvalScope s) {
    // if() only evaluates the branch it takes.
    if (e.name == 'if') {
      _arity(e, 3);
      return xBool(_eval(e.args[0], s)) ? _eval(e.args[1], s) : _eval(e.args[2], s);
    }
    final args = [for (final a in e.args) _eval(a, s)];
    dynamic arg(int i) => i < args.length ? args[i] : '';

    switch (e.name) {
      case 'selected':
        _arity(e, 2);
        return _tokens(arg(0)).contains(xString(arg(1)));
      case 'count-selected':
        _arity(e, 1);
        return _tokens(arg(0)).length.toDouble();
      case 'concat':
        return args.map((a) => a is List ? a.map(xString).join() : xString(a)).join();
      case 'join':
        _arity(e, 2);
        final list = arg(1) is List ? arg(1) as List : [arg(1)];
        return list.map(xString).where((v) => v.isNotEmpty).join(xString(arg(0)));
      case 'string-length':
        return xString(args.isEmpty ? s.current : arg(0)).length.toDouble();
      case 'substr':
        final str = xString(arg(0));
        final start = xNumber(arg(1)).toInt().clamp(0, str.length);
        final end = args.length > 2 ? xNumber(arg(2)).toInt().clamp(start, str.length) : str.length;
        return str.substring(start, end);
      case 'contains':
        return xString(arg(0)).contains(xString(arg(1)));
      case 'starts-with':
        return xString(arg(0)).startsWith(xString(arg(1)));
      case 'ends-with':
        return xString(arg(0)).endsWith(xString(arg(1)));
      case 'normalize-space':
        return xString(args.isEmpty ? s.current : arg(0)).trim().replaceAll(RegExp(r'\s+'), ' ');
      case 'regex':
        _arity(e, 2);
        try {
          return RegExp(xString(arg(1))).hasMatch(xString(arg(0)));
        } on FormatException {
          throw ExpressionError('Invalid regex "${xString(arg(1))}".');
        }
      case 'today':
        return DateFormat('yyyy-MM-dd').format(_now());
      case 'now':
        return DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(_now());
      case 'int':
        final n = xNumber(arg(0));
        return n.isNaN || n.isInfinite ? n : n.truncateToDouble();
      case 'number':
        return xNumber(arg(0));
      case 'round':
        final n = xNumber(arg(0));
        final places = args.length > 1 ? xNumber(arg(1)).toInt() : 0;
        final f = math.pow(10, places);
        return (n * f).roundToDouble() / f;
      case 'abs':
        return xNumber(arg(0)).abs();
      case 'pow':
        return math.pow(xNumber(arg(0)), xNumber(arg(1))).toDouble();
      case 'string':
        return xString(args.isEmpty ? s.current : arg(0));
      case 'boolean':
        return xBool(arg(0));
      case 'not':
        return !xBool(arg(0));
      case 'true':
        return true;
      case 'false':
        return false;
      case 'coalesce':
        return xString(arg(0)).isNotEmpty ? arg(0) : arg(1);
      case 'count':
        final v = arg(0);
        return (v is List ? v.length : (xString(v).isEmpty ? 0 : 1)).toDouble();
      case 'sum':
        return _flatten(args).map(xNumber).where((n) => !n.isNaN).fold<double>(0, (a, b) => a + b);
      case 'max' || 'min':
        final nums = _flatten(args).map(xNumber).where((n) => !n.isNaN).toList();
        if (nums.isEmpty) return double.nan;
        return nums.reduce(e.name == 'max' ? math.max : math.min);
      case 'position':
        return s.position.toDouble();
      case 'uuid':
        return const Uuid().v4();
      case 'once':
        return arg(0);
      default:
        throw ExpressionError('Unknown function ${e.name}().');
    }
  }

  void _arity(CallExpr e, int n) {
    if (e.args.length != n) throw ExpressionError('${e.name}() takes $n argument${n == 1 ? '' : 's'}.');
  }

  List<String> _tokens(dynamic v) => xString(v).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

  List<dynamic> _flatten(List<dynamic> args) => [for (final a in args) ...(a is List ? a : [a])];
}

// ── XPath conversions, also used by the form engine to store results ──

final _dateLike = RegExp(r'^\d{4}-\d{2}-\d{2}');

double xNumber(dynamic v) {
  if (v == null) return double.nan;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  if (v is List) return v.isEmpty ? double.nan : xNumber(v.first);
  final s = '$v'.trim();
  if (s.isEmpty) return double.nan;
  final n = double.tryParse(s);
  if (n != null) return n;
  if (_dateLike.hasMatch(s)) {
    final d = DateTime.tryParse(s);
    if (d == null) return double.nan;
    final asUtc = s.length == 10 ? DateTime.utc(d.year, d.month, d.day) : d;
    return asUtc.millisecondsSinceEpoch / Duration.millisecondsPerDay;
  }
  return double.nan;
}

String xString(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) {
    if (v.isNaN || v.isInfinite) return '';
    return v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
  }
  if (v is List) return v.isEmpty ? '' : xString(v.first);
  return '$v';
}

bool xBool(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is List) return v.isNotEmpty;
  return '$v'.isNotEmpty;
}
