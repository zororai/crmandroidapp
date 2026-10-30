import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data_collection/form_logic.dart';
import '../db/repository.dart';

// Renders one CRM data collection form from its schema (sections →
// questions) and saves the answers locally. Answer formats match what the
// CRM web form posts: dates yyyy-MM-dd, datetimes yyyy-MM-ddTHH:mm, times
// HH:mm, yes_no as 'yes'/'no', select_multiple as a list of option values.
class FormFillScreen extends StatefulWidget {
  const FormFillScreen({
    super.key,
    required this.form,
    this.submission,
  });

  final Map<String, dynamic> form; // row from the local forms table
  final Map<String, dynamic>? submission; // existing row to edit or view

  @override
  State<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends State<FormFillScreen> {
  final _repo = Repository();
  late final Map<String, dynamic> _schema;
  late final Map<String, dynamic> _answers;
  final _textControllers = <String, TextEditingController>{};
  Map<String, String> _errors = {};
  String? _uid;
  bool _saving = false;

  // Finalized-but-unsent submissions stay editable, as in Kobo; only what
  // the CRM already has is locked.
  bool get _readOnly => widget.submission?['status'] == 'synced';

  @override
  void initState() {
    super.initState();
    _schema = jsonDecode(widget.form['schema'] as String) as Map<String, dynamic>;
    final existing = widget.submission?['answers'] as String?;
    _answers = existing != null ? jsonDecode(existing) as Map<String, dynamic> : {};
    _uid = widget.submission?['submissionUid'] as String?;
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _setAnswer(String id, dynamic value) {
    setState(() {
      if (isEmptyAnswer(value)) {
        _answers.remove(id);
      } else {
        _answers[id] = value;
      }
      _errors.remove(id);
    });
  }

  Future<void> _save({required bool finalize}) async {
    var answers = _answers;
    if (finalize) {
      final errors = validateAnswers(_schema, _answers);
      if (errors.isNotEmpty) {
        setState(() => _errors = errors);
        _showMessage('Fix ${errors.length} question(s) before finalizing.');
        return;
      }
      answers = visibleAnswersOnly(_schema, _answers);
    }

    setState(() => _saving = true);
    try {
      _uid = await _repo.saveSubmission(
        uid: _uid,
        assignmentId: widget.form['assignmentId'] as int,
        formName: widget.form['formName'] as String? ?? '',
        answers: answers,
        finalize: finalize,
      );
      if (!mounted) return;
      _showMessage(finalize ? 'Finalized — it will upload on the next sync.' : 'Draft saved.');
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sections = sectionsOf(_schema);
    final failedMessage = widget.submission?['status'] == 'failed' ? widget.submission!['errorMessage'] as String? : null;

    return Scaffold(
      appBar: AppBar(title: Text(widget.form['formName'] as String? ?? 'Form')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          if (failedMessage != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('The CRM rejected this submission: $failedMessage\nCorrect it and finalize again.'),
              ),
            ),
          if (_readOnly)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('This submission is already in the CRM and can no longer be edited.', style: TextStyle(color: Colors.grey)),
            ),
          for (final section in sections) _buildSection(section),
          if (sections.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('This form has no questions.')),
            ),
        ],
      ),
      bottomNavigationBar: _readOnly
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving ? null : () => _save(finalize: false),
                        child: const Text('Save draft'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : () => _save(finalize: true),
                        child: const Text('Finalize'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSection(Map<String, dynamic> section) {
    final visible = questionsOf(section).where((q) => isVisible(q, _answers)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if ((section['title'] as String?)?.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(section['title'] as String, style: Theme.of(context).textTheme.titleMedium),
              ),
            for (final q in visible) _buildQuestion(q),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion(Map<String, dynamic> q) {
    final id = q['id'] as String;
    final hint = (q['hint'] ?? q['description']) as String?;
    final error = _errors[id];

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: q['label'] as String? ?? id, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (q['required'] == true) const TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ])),
          if (hint != null && hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          const SizedBox(height: 6),
          IgnorePointer(ignoring: _readOnly, child: _buildInput(q)),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(error, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }

  Widget _buildInput(Map<String, dynamic> q) {
    final id = q['id'] as String;
    final type = q['type'] as String?;
    final options = ((q['options'] as List?) ?? const []).cast<Map<String, dynamic>>();

    switch (type) {
      case 'select_one':
        return Column(
          children: [
            for (final o in options)
              RadioListTile<dynamic>(
                value: o['value'],
                groupValue: _answers[id],
                onChanged: (v) => _setAnswer(id, v),
                title: Text('${o['label'] ?? o['value']}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        );

      case 'select_multiple':
        final selected = List<dynamic>.from((_answers[id] as List?) ?? const []);
        return Column(
          children: [
            for (final o in options)
              CheckboxListTile(
                value: selected.contains(o['value']),
                onChanged: (checked) {
                  checked == true ? selected.add(o['value']) : selected.remove(o['value']);
                  _setAnswer(id, selected);
                },
                title: Text('${o['label'] ?? o['value']}'),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        );

      case 'yes_no':
        return SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'yes', label: Text('Yes')),
            ButtonSegment(value: 'no', label: Text('No')),
          ],
          selected: {if (_answers[id] != null) _answers[id].toString()},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) => _setAnswer(id, s.isEmpty ? null : s.first),
        );

      case 'date':
      case 'datetime':
      case 'time':
        return _buildPicker(id, type!);

      default:
        return _buildTextInput(id, type);
    }
  }

  Widget _buildTextInput(String id, String? type) {
    final controller = _textControllers.putIfAbsent(
      id,
      () => TextEditingController(text: _answers[id]?.toString() ?? ''),
    );
    final isNumber = numberTypes.contains(type);

    return TextField(
      controller: controller,
      readOnly: _readOnly,
      maxLines: type == 'long_text' ? 4 : 1,
      keyboardType: switch (type) {
        'integer' => TextInputType.number,
        'number' || 'decimal' => const TextInputType.numberWithOptions(decimal: true, signed: true),
        'email' => TextInputType.emailAddress,
        'phone' => TextInputType.phone,
        'long_text' => TextInputType.multiline,
        _ => TextInputType.text,
      },
      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
      // Numbers are stored as numbers when they parse, so the CRM's exports
      // and conditions see 5, not "5"; anything else stays as typed so
      // validation can flag it.
      onChanged: (text) {
        final trimmed = text.trim();
        _setAnswer(id, isNumber ? (num.tryParse(trimmed) ?? trimmed) : text);
      },
    );
  }

  Widget _buildPicker(String id, String type) {
    final current = _answers[id] as String?;

    Future<void> pick() async {
      final now = DateTime.now();
      final existing = current != null ? DateTime.tryParse(type == 'time' ? '1970-01-01T$current' : current) : null;

      DateTime? date;
      if (type != 'time') {
        date = await showDatePicker(
          context: context,
          initialDate: existing ?? now,
          firstDate: DateTime(1900),
          lastDate: DateTime(now.year + 10),
        );
        if (date == null) return;
      }

      TimeOfDay? time;
      if (type != 'date') {
        if (!mounted) return;
        time = await showTimePicker(
          context: context,
          initialTime: existing != null ? TimeOfDay.fromDateTime(existing) : TimeOfDay.now(),
        );
        if (time == null) return;
      }

      final hhmm = time == null ? '' : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
      _setAnswer(id, switch (type) {
        'date' => DateFormat('yyyy-MM-dd').format(date!),
        'time' => hhmm,
        _ => '${DateFormat('yyyy-MM-dd').format(date!)}T$hhmm',
      });
    }

    return OutlinedButton.icon(
      onPressed: pick,
      icon: Icon(type == 'time' ? Icons.access_time : Icons.calendar_today, size: 18),
      label: Text(current?.replaceFirst('T', ' ') ?? 'Select ${type == 'datetime' ? 'date & time' : type}'),
      style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
    );
  }
}
