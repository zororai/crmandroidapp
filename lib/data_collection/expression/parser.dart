// Lexer + recursive-descent parser for the XLSForm expression subset used in
// relevant / constraint / calculation / required / default:
//   ${field}  .  ..  numbers  'strings'  "strings"
//   or  and  =  !=  <  <=  >  >=  +  -  *  div  mod  unary -
//   function(args…)   e.g. selected(${x}, 'a'), if(…), today()
// Precedence follows XPath: or < and < equality < relational < additive <
// multiplicative < unary.

sealed class Expr {}

class LiteralExpr extends Expr {
  LiteralExpr(this.value);
  final Object value; // String or double
}

class RefExpr extends Expr {
  RefExpr(this.name);
  final String name;
}

class CurrentExpr extends Expr {} // '.' — the value being constrained

class ParentExpr extends Expr {} // '..' — only meaningful as position(..)

class CallExpr extends Expr {
  CallExpr(this.name, this.args);
  final String name;
  final List<Expr> args;
}

class BinaryExpr extends Expr {
  BinaryExpr(this.op, this.left, this.right);
  final String op;
  final Expr left;
  final Expr right;
}

class NegateExpr extends Expr {
  NegateExpr(this.operand);
  final Expr operand;
}

class ExpressionError implements Exception {
  ExpressionError(this.message);
  final String message;

  @override
  String toString() => message;
}

enum _T { number, string, ref, dot, dotdot, ident, lparen, rparen, comma, op, eof }

class _Token {
  const _Token(this.type, this.text);
  final _T type;
  final String text;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
bool _isIdentStart(String c) => RegExp(r'[A-Za-z_]').hasMatch(c);
bool _isIdentPart(String c) => RegExp(r'[A-Za-z0-9_:\-]').hasMatch(c);

List<_Token> _tokenize(String src) {
  final tokens = <_Token>[];
  var i = 0;
  String at(int k) => k < src.length ? src[k] : '';

  while (i < src.length) {
    final c = src[i];
    if (c.trim().isEmpty) {
      i++;
    } else if (c == r'$' && at(i + 1) == '{') {
      final end = src.indexOf('}', i);
      if (end < 0) throw ExpressionError(r'Missing "}" after "${".');
      tokens.add(_Token(_T.ref, src.substring(i + 2, end).trim()));
      i = end + 1;
    } else if (c == "'" || c == '"') {
      final end = src.indexOf(c, i + 1);
      if (end < 0) throw ExpressionError('Unclosed string.');
      tokens.add(_Token(_T.string, src.substring(i + 1, end)));
      i = end + 1;
    } else if (_isDigit(c) || (c == '.' && at(i + 1).isNotEmpty && _isDigit(at(i + 1)))) {
      final start = i;
      while (i < src.length && (_isDigit(src[i]) || src[i] == '.')) {
        i++;
      }
      tokens.add(_Token(_T.number, src.substring(start, i)));
    } else if (c == '.') {
      final two = at(i + 1) == '.';
      tokens.add(_Token(two ? _T.dotdot : _T.dot, two ? '..' : '.'));
      i += two ? 2 : 1;
    } else if (c == '(') {
      tokens.add(const _Token(_T.lparen, '('));
      i++;
    } else if (c == ')') {
      tokens.add(const _Token(_T.rparen, ')'));
      i++;
    } else if (c == ',') {
      tokens.add(const _Token(_T.comma, ','));
      i++;
    } else if ((c == '!' || c == '<' || c == '>') && at(i + 1) == '=') {
      tokens.add(_Token(_T.op, '$c='));
      i += 2;
    } else if ('=<>+-*'.contains(c)) {
      tokens.add(_Token(_T.op, c));
      i++;
    } else if (_isIdentStart(c)) {
      final start = i;
      while (i < src.length && _isIdentPart(src[i])) {
        i++;
      }
      tokens.add(_Token(_T.ident, src.substring(start, i)));
    } else {
      throw ExpressionError('Unexpected "$c".');
    }
  }
  tokens.add(const _Token(_T.eof, ''));
  return tokens;
}

class ExpressionParser {
  ExpressionParser(String source) : _tokens = _tokenize(source);

  final List<_Token> _tokens;
  var _pos = 0;

  _Token get _peek => _tokens[_pos];
  _Token _next() => _tokens[_pos++];

  bool _isOp(String op) => _peek.type == _T.op && _peek.text == op;
  bool _isWord(String word) => _peek.type == _T.ident && _peek.text == word;

  Expr parse() {
    final e = _or();
    if (_peek.type != _T.eof) throw ExpressionError('Unexpected "${_peek.text}".');
    return e;
  }

  Expr _binaryLevel(Expr Function() operand, bool Function() atOperator) {
    var left = operand();
    while (atOperator()) {
      final op = _next().text;
      left = BinaryExpr(op, left, operand());
    }
    return left;
  }

  Expr _or() => _binaryLevel(_and, () => _isWord('or'));
  Expr _and() => _binaryLevel(_equality, () => _isWord('and'));
  Expr _equality() => _binaryLevel(_relational, () => _isOp('=') || _isOp('!='));
  Expr _relational() => _binaryLevel(_additive, () => _isOp('<') || _isOp('<=') || _isOp('>') || _isOp('>='));
  Expr _additive() => _binaryLevel(_multiplicative, () => _isOp('+') || _isOp('-'));
  Expr _multiplicative() => _binaryLevel(_unary, () => _isOp('*') || _isWord('div') || _isWord('mod'));

  Expr _unary() {
    if (_isOp('-')) {
      _next();
      return NegateExpr(_unary());
    }
    return _primary();
  }

  Expr _primary() {
    final t = _next();
    switch (t.type) {
      case _T.number:
        return LiteralExpr(double.parse(t.text));
      case _T.string:
        return LiteralExpr(t.text);
      case _T.ref:
        return RefExpr(t.text);
      case _T.dot:
        return CurrentExpr();
      case _T.dotdot:
        return ParentExpr();
      case _T.lparen:
        final inner = _or();
        _expect(_T.rparen, ')');
        return inner;
      case _T.ident:
        if (_peek.type != _T.lparen) {
          throw ExpressionError('"${t.text}" is not supported — refer to questions as \${name}.');
        }
        _next();
        final args = <Expr>[];
        if (_peek.type != _T.rparen) {
          args.add(_or());
          while (_peek.type == _T.comma) {
            _next();
            args.add(_or());
          }
        }
        _expect(_T.rparen, ')');
        return CallExpr(t.text, args);
      default:
        throw ExpressionError(t.type == _T.eof ? 'Expression ends too early.' : 'Unexpected "${t.text}".');
    }
  }

  void _expect(_T type, String text) {
    if (_next().type != type) throw ExpressionError('Expected "$text".');
  }
}
