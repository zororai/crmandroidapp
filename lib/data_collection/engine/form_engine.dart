import '../expression/evaluator.dart';
import '../models/form_schema.dart';

// Where a question sits: the chain of repeat instances it's inside,
// outermost first. Top-level questions have no frames.
class RepeatFrame {
  const RepeatFrame(this.name, this.index);

  final String name;
  final int index;
}

// Stable key for a question instance, e.g. "members[1]/member_age".
String fieldKey(List<RepeatFrame> frames, String name) => [for (final f in frames) '${f.name}[${f.index}]', name].join('/');

bool isEmptyValue(dynamic v) => v == null || v == '' || (v is List && v.isEmpty);

class FieldIssue {
  const FieldIssue(this.node, this.frames, this.message);

  final FormNode node;
  final List<RepeatFrame> frames;
  final String message;

  String get key => fieldKey(frames, node.name);
}

enum RenderKind { group, question, repeatInstance, repeatAdd }

// One row of the scrolling form. The form is flattened so a ListView.builder
// only builds what's on screen, which keeps large forms fast.
class RenderItem {
  const RenderItem(this.kind, this.node, this.frames, this.depth);

  final RenderKind kind;
  final FormNode node;
  final List<RepeatFrame> frames; // for repeatInstance: includes this instance
  final int depth;

  String get key => '${kind.name}:${fieldKey(frames, node.name)}';
}

// Holds the answers for one submission and applies the form's rules to them.
// Data layout matches the submission payload: a flat map of field name →
// value (XLSForm names are unique per form, so groups don't nest), with each
// repeat stored as a list of maps.
//
// Value formats: integer → int, decimal → num, select_multiple → "a b"
// (space-separated, as XLSForm/Kobo store it), date → yyyy-MM-dd,
// time → HH:mm, datetime → yyyy-MM-ddTHH:mm:ss, geopoint → "lat lng alt acc",
// photo → file name.
class FormEngine {
  FormEngine(this.schema, {Map<String, dynamic>? data, ExpressionEvaluator? evaluator})
      : data = data ?? <String, dynamic>{},
        _eval = evaluator ?? ExpressionEvaluator() {
    _index(schema.children, const []);
    if (data == null) _applyDefaults(schema.children, this.data, const []);
    recalculate();
  }

  final FormSchema schema;
  final Map<String, dynamic> data;
  final ExpressionEvaluator _eval;

  final _byName = <String, FormNode>{}; // insertion order = form order
  final _repeatChain = <String, List<String>>{}; // enclosing repeats, outermost first

  // Expressions that failed to parse/evaluate — a form design problem,
  // shown to the user as a warning rather than crashing the form.
  final expressionErrors = <String>{};

  void _index(List<FormNode> nodes, List<String> repeats) {
    for (final n in nodes) {
      if (n.name.isNotEmpty) {
        _byName[n.name] = n;
        _repeatChain[n.name] = repeats;
      }
      if (n.isContainer) _index(n.children, n.isRepeat ? [...repeats, n.name] : repeats);
    }
  }

  FormNode? node(String name) => _byName[name];

  // ── Values ──

  Map<String, dynamic> _container(List<RepeatFrame> frames) {
    var c = data;
    for (final f in frames) {
      c = (c[f.name] as List)[f.index] as Map<String, dynamic>;
    }
    return c;
  }

  dynamic valueOf(List<RepeatFrame> frames, String name) => _container(frames)[name];

  void setValue(List<RepeatFrame> frames, String name, dynamic value) {
    final c = _container(frames);
    if (isEmptyValue(value)) {
      c.remove(name);
    } else {
      c[name] = value;
    }
    recalculate();
  }

  int instanceCount(List<RepeatFrame> frames, String repeatName) => ((_container(frames)[repeatName] as List?) ?? const []).length;

  void addRepeatInstance(List<RepeatFrame> frames, FormNode repeat) {
    final c = _container(frames);
    final list = (c[repeat.name] as List?) ?? <dynamic>[];
    c[repeat.name] = list;
    final instance = <String, dynamic>{};
    list.add(instance);
    _applyDefaults(repeat.children, instance, [...frames, RepeatFrame(repeat.name, list.length - 1)]);
    recalculate();
  }

  void removeRepeatInstance(List<RepeatFrame> frames, String repeatName, int index) {
    final c = _container(frames);
    final list = c[repeatName] as List;
    list.removeAt(index);
    if (list.isEmpty) c.remove(repeatName);
    recalculate();
  }

  void _applyDefaults(List<FormNode> nodes, Map<String, dynamic> container, List<RepeatFrame> frames) {
    for (final n in nodes) {
      if (n.isGroup) {
        _applyDefaults(n.children, container, frames);
      } else if (n.hasValue && n.defaultValue != null && container[n.name] == null) {
        final d = n.defaultValue!;
        // A plain literal ("yes", "5", "2024-01-01") unless it calls a
        // function or references a question.
        final raw = d.contains('(') || d.contains(r'${') ? _tryEval(d, frames, null, '') : d;
        final value = _coerce(n, raw);
        if (!isEmptyValue(value)) container[n.name] = value;
      }
    }
  }

  dynamic _coerce(FormNode n, dynamic raw) {
    final s = xString(raw);
    return switch (n.type) {
      'integer' => int.tryParse(s) ?? s,
      'decimal' => num.tryParse(s) ?? s,
      _ => s,
    };
  }

  // ── Expressions ──

  dynamic _resolve(String name, List<RepeatFrame> frames) {
    final n = _byName[name];
    if (n == null) {
      expressionErrors.add('Unknown question \${$name}.');
      return '';
    }

    // Walk down through the repeats that enclose the question: follow the
    // current instance where we're inside it, otherwise take every instance
    // (referencing a repeated question from outside gives a list).
    final chain = _repeatChain[name]!;
    var containers = [data];
    var many = false;
    for (var k = 0; k < chain.length; k++) {
      final frame = k < frames.length && frames[k].name == chain[k] ? frames[k] : null;
      final next = <Map<String, dynamic>>[];
      for (final c in containers) {
        final instances = ((c[chain[k]] as List?) ?? const []).cast<Map<String, dynamic>>();
        if (frame != null) {
          if (frame.index < instances.length) next.add(instances[frame.index]);
        } else {
          next.addAll(instances);
          many = true;
        }
      }
      containers = next;
    }

    // ${repeat} itself → its instances, for count().
    if (n.isRepeat) return [for (final c in containers) ...((c[name] as List?) ?? const [])];

    final values = [for (final c in containers) c[name] ?? ''];
    if (many) return values;
    return values.isEmpty ? '' : values.first;
  }

  dynamic _tryEval(String expr, List<RepeatFrame> frames, dynamic current, dynamic fallback) {
    try {
      return _eval.evaluate(expr, _Scope(this, frames, current));
    } on ExpressionError catch (e) {
      expressionErrors.add('"$expr": ${e.message}');
      return fallback;
    }
  }

  bool _evalBool(String expr, List<RepeatFrame> frames, dynamic current, {required bool fallback}) =>
      xBool(_tryEval(expr, frames, current, fallback));

  bool _relevant(FormNode n, List<RepeatFrame> frames) => n.relevant == null || _evalBool(n.relevant!, frames, null, fallback: true);

  // Replaces ${name} in labels/hints/notes with the current answer.
  String interpolate(String text, List<RepeatFrame> frames) => text.replaceAllMapped(
        RegExp(r'\$\{([^}]+)\}'),
        (m) => xString(_resolve(m[1]!.trim(), frames)),
      );

  // ── Walking the form ──

  // Visits every question instance with whether it's currently shown
  // (its own relevant and every enclosing group/repeat's).
  void _walk(List<FormNode> nodes, List<RepeatFrame> frames, bool parentVisible,
      void Function(FormNode n, List<RepeatFrame> frames, bool visible) visit) {
    for (final n in nodes) {
      final visible = parentVisible && _relevant(n, frames);
      visit(n, frames, visible);
      if (n.isGroup) {
        _walk(n.children, frames, visible, visit);
      } else if (n.isRepeat) {
        final count = instanceCount(frames, n.name);
        for (var i = 0; i < count; i++) {
          _walk(n.children, [...frames, RepeatFrame(n.name, i)], visible, visit);
        }
      }
    }
  }

  // Calculations can depend on each other in any order; two passes settle
  // the forward references XLSForms commonly have.
  void recalculate() {
    for (var pass = 0; pass < 2; pass++) {
      _walk(schema.children, const [], true, (n, frames, visible) {
        if (n.calculation == null || !n.hasValue) return;
        final v = _tryEval(n.calculation!, frames, null, '');
        final c = _container(frames);
        final stored = v is num ? _number(v) : xString(v);
        if (isEmptyValue(stored)) {
          c.remove(n.name);
        } else {
          c[n.name] = stored;
        }
      });
    }
  }

  dynamic _number(num v) {
    if (v.isNaN || v.isInfinite) return '';
    return v == v.truncateToDouble() ? v.toInt() : v;
  }

  List<RenderItem> renderItems() {
    final out = <RenderItem>[];
    void render(List<FormNode> nodes, List<RepeatFrame> frames, int depth) {
      for (final n in nodes) {
        if (!_relevant(n, frames)) continue;
        switch (n.type) {
          case 'group':
            if (n.label.isNotEmpty) out.add(RenderItem(RenderKind.group, n, frames, depth));
            render(n.children, frames, n.label.isNotEmpty ? depth + 1 : depth);
          case 'repeat':
            final count = instanceCount(frames, n.name);
            for (var i = 0; i < count; i++) {
              final inner = [...frames, RepeatFrame(n.name, i)];
              out.add(RenderItem(RenderKind.repeatInstance, n, inner, depth));
              render(n.children, inner, depth + 1);
            }
            out.add(RenderItem(RenderKind.repeatAdd, n, frames, depth));
          case 'calculate':
            break;
          default:
            out.add(RenderItem(RenderKind.question, n, frames, depth));
        }
      }
    }

    render(schema.children, const [], 0);
    return out;
  }

  // ── Validation ──

  String? validateField(FormNode n, List<RepeatFrame> frames) {
    if (!n.isAskable) return null;
    final v = valueOf(frames, n.name);

    if (isEmptyValue(v)) {
      if (n.required != null && _evalBool(n.required!, frames, v, fallback: false)) {
        return n.requiredMessage ?? 'This question is required.';
      }
      return null;
    }
    if (n.type == 'integer' && v is! int) return 'Enter a whole number.';
    if (n.type == 'decimal' && v is! num) return 'Enter a number.';
    if (n.constraint != null && !_evalBool(n.constraint!, frames, v, fallback: true)) {
      return n.constraintMessage ?? 'This answer is not allowed.';
    }
    return null;
  }

  List<FieldIssue> validate() {
    final issues = <FieldIssue>[];
    _walk(schema.children, const [], true, (n, frames, visible) {
      if (!visible) return;
      final message = validateField(n, frames);
      if (message != null) issues.add(FieldIssue(n, frames, message));
    });
    return issues;
  }

  // (answered, total) over the questions currently shown.
  (int, int) progress() {
    var answered = 0;
    var total = 0;
    _walk(schema.children, const [], true, (n, frames, visible) {
      if (!visible || !n.isAskable) return;
      total++;
      if (!isEmptyValue(valueOf(frames, n.name))) answered++;
    });
    return (answered, total);
  }

  // ── Payload ──

  // The data sent to the CRM: answers to hidden questions are left out
  // (they were never asked), and so are notes.
  Map<String, dynamic> payload() {
    Map<String, dynamic> collect(List<FormNode> nodes, Map<String, dynamic> src, List<RepeatFrame> frames, Map<String, dynamic> out) {
      for (final n in nodes) {
        if (!_relevant(n, frames)) continue;
        if (n.isGroup) {
          collect(n.children, src, frames, out);
        } else if (n.isRepeat) {
          final instances = ((src[n.name] as List?) ?? const []).cast<Map<String, dynamic>>();
          if (instances.isEmpty) continue;
          out[n.name] = [
            for (var i = 0; i < instances.length; i++)
              collect(n.children, instances[i], [...frames, RepeatFrame(n.name, i)], <String, dynamic>{}),
          ];
        } else if (n.hasValue && !isEmptyValue(src[n.name])) {
          out[n.name] = src[n.name];
        }
      }
      return out;
    }

    return collect(schema.children, data, const [], <String, dynamic>{});
  }

  // Photo answers anywhere in a payload: (field name, file name).
  List<(String, String)> photoAnswers(Map<String, dynamic> payload) {
    final found = <(String, String)>[];
    void scan(Map<String, dynamic> m) {
      m.forEach((key, value) {
        if (value is List) {
          for (final item in value) {
            if (item is Map<String, dynamic>) scan(item);
          }
        } else if (_byName[key]?.type == 'photo' && value is String) {
          found.add((key, value));
        }
      });
    }

    scan(payload);
    return found;
  }

  // The submission-level location: the first top-level geopoint answered.
  (double, double)? firstLocation(Map<String, dynamic> payload) {
    for (final n in _byName.values) {
      if (n.type != 'geopoint' || _repeatChain[n.name]!.isNotEmpty) continue;
      final parts = xString(payload[n.name]).split(' ');
      final lat = parts.isNotEmpty ? double.tryParse(parts[0]) : null;
      final lng = parts.length > 1 ? double.tryParse(parts[1]) : null;
      if (lat != null && lng != null) return (lat, lng);
    }
    return null;
  }
}

class _Scope implements EvalScope {
  _Scope(this.engine, this.frames, this.current);

  final FormEngine engine;
  final List<RepeatFrame> frames;

  @override
  final dynamic current;

  @override
  dynamic resolve(String name) => engine._resolve(name, frames);

  @override
  int get position => frames.isEmpty ? 0 : frames.last.index + 1;
}
