import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/brand_colors.dart';
import '../learning_setup.dart';
import '../models/learning_models.dart';
import '../widgets/learning_widgets.dart';

// New course: its name, the topics to teach (in order), and the class the
// teacher runs on it. With an existing class: rename the course and add or
// rename topics (topics already in the CRM can't be removed). Works offline.
// Pops with the class uuid when a new course is created.
class CourseEditorScreen extends StatefulWidget {
  const CourseEditorScreen({super.key, this.cohort});

  final LearningCohort? cohort; // null = new course

  @override
  State<CourseEditorScreen> createState() => _CourseEditorScreenState();
}

class _CourseEditorScreenState extends State<CourseEditorScreen> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _className = TextEditingController();
  final _venue = TextEditingController();
  String? _startDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  String? _endDate;
  final _topics = <TopicDraft>[];
  final _topicControllers = <String, TextEditingController>{};
  bool _classNameEdited = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.cohort == null;

  @override
  void initState() {
    super.initState();
    final c = widget.cohort;
    if (c != null) {
      _title.text = c.courseTitle;
      _description.text = c.courseDescription ?? '';
      for (final t in c.topics) {
        _topics.add(TopicDraft(uuid: t.uuid, title: t.title, plannedSessions: t.plannedSessions, isAssessed: t.isAssessed, uploaded: !c.isLocal));
      }
    } else {
      _topics.add(TopicDraft(title: ''));
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _description, _className, _venue, ..._topicControllers.values]) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(TopicDraft t) =>
      _topicControllers.putIfAbsent(t.uuid, () => TextEditingController(text: t.title));

  Future<void> _pickDate(bool start) async {
    final current = DateTime.tryParse((start ? _startDate : _endDate) ?? '') ?? DateTime.now();
    final d = await showDatePicker(context: context, initialDate: current, firstDate: DateTime(2020), lastDate: DateTime(2035));
    if (d == null) return;
    setState(() {
      final v = DateFormat('yyyy-MM-dd').format(d);
      if (start) {
        _startDate = v;
      } else {
        _endDate = v;
      }
    });
  }

  Future<void> _save() async {
    for (final t in _topics) {
      t.title = _controllerFor(t).text.trim();
    }
    final topics = _topics.where((t) => t.title.isNotEmpty).toList();
    final title = _title.text.trim();

    String? error;
    if (title.isEmpty) {
      error = 'Enter the course name.';
    } else if (topics.isEmpty) {
      error = 'Add at least one topic.';
    } else if (_endDate != null && _startDate != null && _endDate!.compareTo(_startDate!) < 0) {
      error = 'The end date is before the start date.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() => _saving = true);
    final setup = LearningSetup();
    final description = _description.text.trim().isEmpty ? null : _description.text.trim();
    if (_isNew) {
      final className = _className.text.trim().isEmpty ? title : _className.text.trim();
      final uuid = await setup.createCourseAndClass(
        title: title,
        description: description,
        topics: topics,
        className: className,
        venue: _venue.text.trim().isEmpty ? null : _venue.text.trim(),
        startDate: _startDate,
        endDate: _endDate,
      );
      if (mounted) Navigator.of(context).pop(uuid);
    } else {
      await setup.updateCourse(widget.cohort!, title: title, description: description, topics: topics);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(
        title: Text(_isNew ? 'New course' : 'Edit course'),
        backgroundColor: const Color(0xFFF7F6F3),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: statusCritical.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [const Icon(Icons.error_outline, color: statusCritical), const SizedBox(width: 10), Expanded(child: Text(_error!))]),
            ),
          _section('Course', [
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Course name', hintText: 'e.g. Baking Basics', border: OutlineInputBorder()),
              onChanged: (v) {
                if (_isNew && !_classNameEdited) _className.text = v;
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Description (optional)', border: OutlineInputBorder()),
            ),
          ]),
          _section('Topics you will teach', [
            const Text('In teaching order. You will assess students on each topic as you teach it.', style: TextStyle(fontSize: 13, color: inkSecondary)),
            const SizedBox(height: 8),
            ReorderableListView(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              physics: const NeverScrollableScrollPhysics(),
              onReorder: (from, to) => setState(() {
                if (to > from) to--;
                _topics.insert(to, _topics.removeAt(from));
              }),
              children: [
                for (final (i, t) in _topics.indexed)
                  Padding(
                    key: ValueKey(t.uuid),
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 14, right: 6),
                          child: CircleAvatar(radius: 12, backgroundColor: brandPurple.withValues(alpha: 0.12), child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: brandPurple))),
                        ),
                      ),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          TextField(
                            controller: _controllerFor(t),
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(hintText: 'Topic title', isDense: true, border: OutlineInputBorder()),
                          ),
                          Row(children: [
                            const Text('Sessions:', style: TextStyle(fontSize: 12, color: inkSecondary)),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.remove_circle_outline, size: 20),
                              onPressed: t.plannedSessions > 1 ? () => setState(() => t.plannedSessions--) : null,
                            ),
                            Text('${t.plannedSessions}'),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.add_circle_outline, size: 20),
                              onPressed: t.plannedSessions < 20 ? () => setState(() => t.plannedSessions++) : null,
                            ),
                            const Spacer(),
                            const Text('Assess', style: TextStyle(fontSize: 12, color: inkSecondary)),
                            Switch(value: t.isAssessed, onChanged: (v) => setState(() => t.isAssessed = v)),
                          ]),
                        ]),
                      ),
                      IconButton(
                        tooltip: t.uploaded ? 'Already in the CRM' : 'Remove topic',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: t.uploaded || _topics.length == 1 ? null : () => setState(() => _topics.remove(t)),
                      ),
                    ]),
                  ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _topics.add(TopicDraft(title: ''))),
                icon: const Icon(Icons.add),
                label: const Text('Add topic'),
              ),
            ),
          ]),
          if (_isNew)
            _section('Your class', [
              TextField(
                controller: _className,
                decoration: const InputDecoration(labelText: 'Class name', helperText: 'Same as the course unless you run several classes', border: OutlineInputBorder()),
                onChanged: (_) => _classNameEdited = true,
              ),
              const SizedBox(height: 12),
              TextField(controller: _venue, decoration: const InputDecoration(labelText: 'Venue (optional)', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _dateButton('Starts', _startDate, () => _pickDate(true))),
                const SizedBox(width: 12),
                Expanded(child: _dateButton('Ends (optional)', _endDate, () => _pickDate(false))),
              ]),
            ]),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: Icon(_isNew ? Icons.arrow_forward : Icons.check),
            label: Text(_isNew ? 'Create course and add students' : 'Save changes'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ),
      ),
    );
  }

  Widget _dateButton(String label, String? value, VoidCallback onTap) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: inkSecondary)),
          const SizedBox(height: 4),
          OutlinedButton.icon(onPressed: onTap, icon: const Icon(Icons.calendar_today, size: 16), label: Text(value == null ? 'Set date' : formatDate(value))),
        ],
      );

  Widget _section(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: hairline)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brandInk)),
          const SizedBox(height: 10),
          ...children,
        ]),
      );
}
