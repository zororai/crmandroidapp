import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/brand_colors.dart';
import '../course_catalogue.dart';
import '../learning_setup.dart';
import '../models/learning_models.dart';
import '../widgets/learning_widgets.dart';

// New course: choose the course from the CRM's list (the same list as the
// skill interests in beneficiary profiling), then the topics you will teach
// and your class details. With an existing class: add or rename that
// class's topics (ones already in the CRM can't be removed). Works offline
// once the list has been downloaded. Pops with the class uuid when created.
class CourseEditorScreen extends StatefulWidget {
  const CourseEditorScreen({super.key, this.cohort});

  final LearningCohort? cohort; // null = new class

  @override
  State<CourseEditorScreen> createState() => _CourseEditorScreenState();
}

class _CourseEditorScreenState extends State<CourseEditorScreen> {
  final _className = TextEditingController();
  final _venue = TextEditingController();
  String? _startDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  String? _endDate;
  final _topics = <TopicDraft>[];
  final _topicControllers = <String, TextEditingController>{};
  List<CatalogueCourse> _catalogue = [];
  bool _catalogueDownloaded = true;
  CatalogueCourse? _course;
  bool _classNameEdited = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.cohort == null;

  @override
  void initState() {
    super.initState();
    final c = widget.cohort;
    if (c != null) {
      for (final t in c.topics.where((t) => t.isClassTopic || c.isLocal)) {
        _topics.add(TopicDraft(uuid: t.uuid, title: t.title, plannedSessions: t.plannedSessions, isAssessed: t.isAssessed, uploaded: !c.isLocal));
      }
      if (_topics.isEmpty) _topics.add(TopicDraft(title: ''));
    } else {
      _topics.add(TopicDraft(title: ''));
      _loadCatalogue();
    }
  }

  Future<void> _loadCatalogue() async {
    final cached = await CourseCatalogueCache.load();
    final downloaded = await CourseCatalogueCache.isDownloaded();
    if (mounted) {
      setState(() {
        _catalogue = cached;
        _catalogueDownloaded = downloaded;
      });
    }
    final latest = await CourseCatalogueCache.refresh();
    final nowDownloaded = await CourseCatalogueCache.isDownloaded();
    if (mounted) {
      setState(() {
        _catalogue = latest;
        _catalogueDownloaded = nowDownloaded;
        if (_course != null) _course = latest.where((c) => c.code == _course!.code).firstOrNull;
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_className, _venue, ..._topicControllers.values]) {
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

    String? error;
    if (_isNew && _course == null) {
      error = 'Choose the course.';
    } else if (_isNew && _course!.clientUuid == null) {
      error = 'Connect to the internet once to download the course list, then try again.';
    } else if (topics.isEmpty) {
      error = 'Add at least one topic you will teach.';
    } else if (_endDate != null && _startDate != null && _endDate!.compareTo(_startDate!) < 0) {
      error = 'The end date is before the start date.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() => _saving = true);
    final setup = LearningSetup();
    if (_isNew) {
      final uuid = await setup.createClass(
        course: _course!,
        topics: topics,
        className: _className.text.trim().isEmpty ? _course!.title : _className.text.trim(),
        venue: _venue.text.trim().isEmpty ? null : _venue.text.trim(),
        startDate: _startDate,
        endDate: _endDate,
      );
      if (mounted) Navigator.of(context).pop(uuid);
    } else {
      await setup.updateClassTopics(widget.cohort!, topics);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shared = widget.cohort?.topics.where((t) => !t.isClassTopic && !(widget.cohort?.isLocal ?? false)).toList() ?? const <LearningTopic>[];

    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(
        title: Text(_isNew ? 'New course' : 'Topics'),
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
          if (_isNew)
            _section('Course', [
              DropdownButtonFormField<String>(
                initialValue: _course?.code,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Course', border: OutlineInputBorder()),
                hint: const Text('Choose from the course list'),
                items: [for (final c in _catalogue) DropdownMenuItem(value: c.code, child: Text(c.title))],
                onChanged: (code) => setState(() {
                  _course = _catalogue.firstWhere((c) => c.code == code);
                  if (!_classNameEdited) _className.text = _course!.title;
                  _error = null;
                }),
              ),
              const SizedBox(height: 8),
              Text(
                _catalogueDownloaded
                    ? 'The same list as the skill interests in beneficiary profiling. Youth who chose this course appear when you add students.'
                    : 'Showing the built-in list. Connect to the internet once to download the CRM\'s course list.',
                style: const TextStyle(fontSize: 12, color: inkSecondary),
              ),
              if (_course?.description != null) ...[
                const SizedBox(height: 8),
                Text(_course!.description!, style: const TextStyle(color: inkSecondary)),
              ],
            ]),
          _section(_isNew ? 'Topics you will teach' : 'Your topics', [
            const Text('In teaching order. You assess each student on a topic when you teach it.', style: TextStyle(fontSize: 13, color: inkSecondary)),
            if (shared.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Set by the course: ${shared.map((t) => t.title).join(', ')}', style: const TextStyle(fontSize: 12, color: inkMuted)),
            ],
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
                decoration: const InputDecoration(labelText: 'Class name', helperText: 'e.g. "Tailoring - Mbare, Nov 2026"', border: OutlineInputBorder()),
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
            label: Text(_isNew ? 'Create class and add students' : 'Save topics'),
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
