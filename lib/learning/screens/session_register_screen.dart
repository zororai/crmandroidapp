import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../db/repository.dart';
import '../../data_collection/sync/sync_coordinator.dart';
import '../../theme/brand_colors.dart';
import '../db/learning_store.dart';
import '../models/learning_models.dart';
import '../widgets/learning_widgets.dart';

const _statuses = [
  ('present', 'P', 'Present', statusGood),
  ('late', 'L', 'Late', statusWarning),
  ('absent', 'A', 'Absent', statusCritical),
  ('excused', 'E', 'Excused', inkMuted),
];

// The attendance register for one session: when it ran (start, end,
// duration), who came (present / late with arrival time / absent / excused
// with a reason), which topics were covered (fully or partly), and — for
// assessed topics — each student's progress and score.
//
// Opens empty for a new session, from a local record to continue or fix it,
// or from a record already on the server to edit it (same client_uuid, so
// the CRM applies it as an update).
class SessionRegisterScreen extends StatefulWidget {
  const SessionRegisterScreen({super.key, required this.cohortId, this.session, this.local, this.serverRecord});

  final int cohortId;
  final PlannedSession? session;
  final LocalSessionRecord? local;
  final Map<String, dynamic>? serverRecord;

  @override
  State<SessionRegisterScreen> createState() => _SessionRegisterScreenState();
}

class _SessionRegisterScreenState extends State<SessionRegisterScreen> {
  final _repo = Repository();
  final _notes = TextEditingController();
  LearningCohort? _cohort;
  late LearningStore _store;
  int _userId = 0;
  String _userName = '';

  late String _uuid;
  late String _heldOn;
  DateTime? _startedAt;
  DateTime? _endedAt;
  final _coverage = <int, String>{}; // topicId → full | partial
  final _marks = <int, Map<String, dynamic>>{}; // enrollmentId → {status, arrived_at, reason, marked_at}
  final _progress = <String, Map<String, dynamic>>{}; // "enrollment:topic" → {status, score} — only rows changed here
  final _reasonControllers = <int, TextEditingController>{};
  final _scoreControllers = <String, TextEditingController>{};
  bool _readOnly = false;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final c in [..._reasonControllers.values, ..._scoreControllers.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    _store = await LearningStore.open();
    final user = await _repo.getCurrentUser();
    _userId = user?['userId'] as int? ?? 0;
    _userName = user?['name'] as String? ?? '';
    final cohort = await _store.cohort(widget.cohortId);

    final local = widget.local;
    final server = widget.serverRecord;
    final session = widget.session;
    if (local != null) {
      _uuid = local.clientUuid;
      _heldOn = local.heldOn;
      _startedAt = local.startedAt;
      _endedAt = local.endedAt;
      _notes.text = local.notes;
      _fill(local.topics, local.attendance);
      for (final p in local.topicProgress) {
        _progress['${p['enrollment_id']}:${p['topic_id']}'] = {'status': p['status'], 'score': p['score']};
      }
      _readOnly = !local.isEditable;
    } else if (server != null) {
      _uuid = server['client_uuid'] as String;
      _heldOn = server['held_on'] as String;
      _startedAt = DateTime.tryParse(server['started_at'] as String? ?? '')?.toLocal();
      _endedAt = DateTime.tryParse(server['ended_at'] as String? ?? '')?.toLocal();
      _notes.text = server['notes'] as String? ?? '';
      _fill(((server['topics'] as List?) ?? const []).cast<Map<String, dynamic>>(),
          ((server['attendance'] as List?) ?? const []).cast<Map<String, dynamic>>());
      _readOnly = server['editable'] != true;
    } else {
      _uuid = const Uuid().v4();
      final today = DateTime.now();
      _heldOn = session?.date ?? DateFormat('yyyy-MM-dd').format(today);
      // A past session: assume it ran at its planned times (editable).
      if (session != null && session.date.compareTo(DateFormat('yyyy-MM-dd').format(today)) < 0) {
        _startedAt = _at(session.date, session.startTime);
        _endedAt = _at(session.date, session.endTime);
      }
      final planned = session?.plannedTopicId;
      if (planned != null) _coverage[planned] = 'full';
    }
    if (mounted) setState(() => _cohort = cohort);
  }

  void _fill(List<Map<String, dynamic>> topics, List<Map<String, dynamic>> attendance) {
    for (final t in topics) {
      _coverage[t['topic_id'] as int] = t['coverage'] as String;
    }
    for (final a in attendance) {
      _marks[a['enrollment_id'] as int] = Map<String, dynamic>.of(a);
      _reasonControllers[a['enrollment_id'] as int] = TextEditingController(text: a['reason'] as String? ?? '');
    }
  }

  DateTime? _at(String date, String? hhmm) => hhmm == null ? null : DateTime.tryParse('${date}T$hhmm:00');

  // ── Edits ──

  void _changed(VoidCallback f) {
    if (_readOnly) return;
    setState(() {
      f();
      _dirty = true;
    });
  }

  void _mark(int enrollmentId, String status) => _changed(() {
        final now = DateTime.now();
        final current = _marks[enrollmentId];
        _marks[enrollmentId] = {
          'enrollment_id': enrollmentId,
          'status': status,
          'arrived_at': status == 'late' ? (current?['arrived_at'] ?? now.toUtc().toIso8601String()) : null,
          'reason': (status == 'absent' || status == 'excused') ? (current?['reason']) : null,
          'marked_at': now.toUtc().toIso8601String(),
        };
      });

  void _markAllPresent(List<LearningStudent> students) => _changed(() {
        final now = DateTime.now().toUtc().toIso8601String();
        for (final s in students) {
          _marks.putIfAbsent(s.enrollmentId, () => {'enrollment_id': s.enrollmentId, 'status': 'present', 'arrived_at': null, 'reason': null, 'marked_at': now});
        }
      });

  Future<void> _pickTime(bool start) async {
    final current = (start ? _startedAt : _endedAt) ?? DateTime.now();
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (t == null) return;
    final d = DateTime.parse(_heldOn);
    _changed(() {
      final v = DateTime(d.year, d.month, d.day, t.hour, t.minute);
      if (start) {
        _startedAt = v;
      } else {
        _endedAt = v;
      }
    });
  }

  Future<void> _pickArrival(int enrollmentId) async {
    final m = _marks[enrollmentId]!;
    final current = DateTime.tryParse(m['arrived_at'] as String? ?? '')?.toLocal() ?? DateTime.now();
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (t == null) return;
    final d = DateTime.parse(_heldOn);
    _changed(() => m['arrived_at'] = DateTime(d.year, d.month, d.day, t.hour, t.minute).toUtc().toIso8601String());
  }

  Future<void> _pickDate() async {
    final current = DateTime.parse(_heldOn);
    final d = await showDatePicker(context: context, initialDate: current, firstDate: DateTime(2020), lastDate: DateTime.now());
    if (d != null) _changed(() => _heldOn = DateFormat('yyyy-MM-dd').format(d));
  }

  // ── Save ──

  Future<bool> _save({required bool finish}) async {
    final c = _cohort!;
    final active = c.roster.where((s) => s.isActive).toList();

    if (finish) {
      final problem = _problem();
      if (problem != null) {
        _show(problem);
        return false;
      }
      final unmarked = active.where((s) => !_marks.containsKey(s.enrollmentId)).length;
      if (unmarked > 0) {
        final go = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('$unmarked student${unmarked == 1 ? '' : 's'} not marked'),
            content: const Text('Unmarked students count as absent. Finish anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back to register')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Finish')),
            ],
          ),
        );
        if (go != true) return false;
      }
    }

    setState(() => _saving = true);
    for (final e in _reasonControllers.entries) {
      final m = _marks[e.key];
      if (m != null && (m['status'] == 'absent' || m['status'] == 'excused')) {
        m['reason'] = e.value.text.trim().isEmpty ? null : e.value.text.trim();
      }
    }
    final existing = await _store.record(_uuid);
    await _store.saveRecord(LocalSessionRecord(
      clientUuid: _uuid,
      cohortId: widget.cohortId,
      cohortSessionId: widget.session?.id ?? widget.local?.cohortSessionId ?? (widget.serverRecord?['cohort_session_id'] as int?),
      heldOn: _heldOn,
      startedAt: _startedAt,
      endedAt: _endedAt,
      notes: _notes.text.trim(),
      topics: [for (final e in _coverage.entries) {'topic_id': e.key, 'coverage': e.value, 'note': null}],
      // Only students still in the cohort are sent.
      attendance: _marks.values.where((m) => c.student(m['enrollment_id'] as int)?.isActive ?? false).toList(),
      topicProgress: [
        for (final e in _progress.entries)
          {
            'enrollment_id': int.parse(e.key.split(':')[0]),
            'topic_id': int.parse(e.key.split(':')[1]),
            'status': e.value['status'],
            'score': e.value['score'],
          },
      ],
      status: finish ? RecordStatus.finalized : RecordStatus.draft,
      ownerUserId: _userId,
      ownerName: _userName,
      createdAt: existing?.createdAt,
    ));
    _dirty = false;
    if (finish) await SyncCoordinator.instance.onFinalized();
    if (mounted) setState(() => _saving = false);
    return true;
  }

  String? _problem() {
    if (DateTime.parse(_heldOn).isAfter(DateTime.now())) return 'The session date is in the future.';
    if (_startedAt != null && _endedAt != null && _endedAt!.isBefore(_startedAt!)) return 'The end time is before the start time.';
    if (_marks.isEmpty) return 'Mark attendance for at least one student.';
    return null;
  }

  void _show(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _finish() async {
    if (await _save(finish: true) && mounted) {
      _show('Session saved. It will be sent when the device is online.');
      Navigator.of(context).pop();
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final c = _cohort;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_dirty) return;
        await _save(finish: false);
        if (context.mounted) {
          _show('Saved as a draft.');
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F6F3),
        appBar: AppBar(
          title: const Text('Session register'),
          backgroundColor: const Color(0xFFF7F6F3),
          surfaceTintColor: Colors.transparent,
        ),
        body: c == null ? const Center(child: CircularProgressIndicator()) : _body(c),
        bottomNavigationBar: c == null || _readOnly
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () async {
                                await _save(finish: false);
                                if (mounted) _show('Saved as a draft.');
                              },
                        child: const Text('Save draft'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: FilledButton(onPressed: _saving ? null : _finish, child: const Text('Finish & send'))),
                  ]),
                ),
              ),
      ),
    );
  }

  Widget _body(LearningCohort c) {
    final active = c.roster.where((s) => s.isActive).toList()..sort((a, b) => a.name.compareTo(b.name));
    final counts = {for (final s in _statuses) s.$1: _marks.values.where((m) => m['status'] == s.$1).length};
    final unmarked = active.where((s) => !_marks.containsKey(s.enrollmentId)).length;
    final assessedCovered = c.topics.where((t) => t.isAssessed && _coverage.containsKey(t.id)).toList();
    final warning = widget.local?.status == RecordStatus.failed ? widget.local!.errorReason : null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (_readOnly)
          _note('This session has been sent and can no longer be changed here.', Icons.lock_outline, inkMuted),
        if (warning != null) _note('The CRM rejected this session: $warning Fix it and finish again.', Icons.error_outline, statusCritical),

        // When
        _section('When', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today, color: brandPurple),
            title: Text(DateFormat('EEEE d MMMM yyyy').format(DateTime.parse(_heldOn))),
            subtitle: widget.session != null ? const Text('Scheduled session') : const Text('Unscheduled session'),
            trailing: widget.session == null && !_readOnly ? TextButton(onPressed: _pickDate, child: const Text('Change')) : null,
          ),
          Row(children: [
            Expanded(child: _timeButton('Started', _startedAt, start: true)),
            const SizedBox(width: 12),
            Expanded(child: _timeButton('Ended', _endedAt, start: false)),
          ]),
          if (_startedAt != null && _endedAt != null && !_endedAt!.isBefore(_startedAt!))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                const Icon(Icons.timer_outlined, size: 18, color: inkSecondary),
                const SizedBox(width: 6),
                Text('Duration ${formatDuration(_endedAt!.difference(_startedAt!))}', style: const TextStyle(color: inkSecondary)),
              ]),
            ),
        ]),

        // Topics
        _section('Topics covered', [
          for (final t in c.topics)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: '${t.position}. ${t.title}', style: const TextStyle(color: brandInk)),
                    if (t.isAssessed) const TextSpan(text: '  · assessed', style: TextStyle(fontSize: 12, color: brandPurple)),
                  ])),
                ),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: 'partial', label: Text('Partly')),
                    ButtonSegment(value: 'full', label: Text('Fully')),
                  ],
                  emptySelectionAllowed: true,
                  selected: {if (_coverage[t.id] != null) _coverage[t.id]!},
                  onSelectionChanged: _readOnly
                      ? null
                      : (v) => _changed(() {
                            if (v.isEmpty) {
                              _coverage.remove(t.id);
                            } else {
                              _coverage[t.id] = v.first;
                            }
                          }),
                ),
              ]),
            ),
        ]),

        // Attendance
        _section('Attendance', [
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final s in _statuses)
              if (counts[s.$1]! > 0) StatusPill(icon: Icons.circle, label: '${counts[s.$1]} ${s.$3.toLowerCase()}', color: s.$4),
            if (unmarked > 0) StatusPill(icon: Icons.radio_button_unchecked, label: '$unmarked not marked', color: inkMuted),
          ]),
          if (!_readOnly && unmarked > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _markAllPresent(active),
                icon: const Icon(Icons.done_all),
                label: const Text('Mark everyone else present'),
              ),
            ),
          const SizedBox(height: 4),
          for (final s in active) _studentRow(s),
        ]),

        // Assessments
        if (assessedCovered.isNotEmpty)
          _section('Assessments', [
            const Text('Record progress for the assessed topics covered in this session.', style: TextStyle(fontSize: 13, color: inkSecondary)),
            for (final t in assessedCovered) ...[
              const SizedBox(height: 12),
              Text(t.title, style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
              for (final s in active) _assessmentRow(c, s, t),
            ],
          ]),

        _section('Notes', [
          TextField(
            controller: _notes,
            readOnly: _readOnly,
            maxLines: 3,
            onChanged: (_) => _dirty = true,
            decoration: const InputDecoration(hintText: 'Anything worth noting about this session', border: OutlineInputBorder()),
          ),
        ]),
      ],
    );
  }

  Widget _note(String text, IconData icon, Color color) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [Icon(icon, color: color), const SizedBox(width: 10), Expanded(child: Text(text))]),
      );

  Widget _section(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: hairline)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brandInk)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  Widget _timeButton(String label, DateTime? value, {required bool start}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: inkSecondary)),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: _readOnly ? null : () => _pickTime(start),
            icon: const Icon(Icons.access_time, size: 18),
            label: Text(value == null ? 'Set time' : DateFormat('HH:mm').format(value)),
          ),
          if (!_readOnly && value == null && _heldOn == DateFormat('yyyy-MM-dd').format(DateTime.now()))
            TextButton(
              onPressed: () => _changed(() {
                if (start) {
                  _startedAt = DateTime.now();
                } else {
                  _endedAt = DateTime.now();
                }
              }),
              child: Text(start ? 'Start now' : 'End now'),
            ),
        ],
      );

  Widget _studentRow(LearningStudent s) {
    final m = _marks[s.enrollmentId];
    final status = m?['status'] as String?;
    final reason = _reasonControllers.putIfAbsent(s.enrollmentId, () => TextEditingController(text: m?['reason'] as String? ?? ''));
    final arrived = DateTime.tryParse(m?['arrived_at'] as String? ?? '')?.toLocal();

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: hairline))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
                if (s.studentRef != null) Text(s.studentRef!, style: const TextStyle(fontSize: 12, color: inkMuted)),
              ]),
            ),
            for (final st in _statuses)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Tooltip(
                  message: st.$3,
                  child: ChoiceChip(
                    label: Text(st.$2),
                    selected: status == st.$1,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    selectedColor: st.$4.withValues(alpha: 0.25),
                    labelStyle: TextStyle(fontWeight: status == st.$1 ? FontWeight.bold : FontWeight.normal, color: brandInk),
                    onSelected: _readOnly ? null : (_) => _mark(s.enrollmentId, st.$1),
                  ),
                ),
              ),
          ]),
          if (status == 'late')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _readOnly ? null : () => _pickArrival(s.enrollmentId),
                icon: const Icon(Icons.schedule, size: 16),
                label: Text(arrived == null ? 'Set arrival time' : 'Arrived ${DateFormat('HH:mm').format(arrived)}'),
              ),
            ),
          if (status == 'absent' || status == 'excused')
            TextField(
              controller: reason,
              readOnly: _readOnly,
              onChanged: (_) => _dirty = true,
              decoration: InputDecoration(
                isDense: true,
                hintText: status == 'excused' ? 'Reason (e.g. clinic visit)' : 'Reason, if known',
                border: const OutlineInputBorder(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _assessmentRow(LearningCohort c, LearningStudent s, LearningTopic t) {
    final key = '${s.enrollmentId}:${t.id}';
    final saved = c.topicProgress.where((p) => p['enrollment_id'] == s.enrollmentId && p['topic_id'] == t.id).firstOrNull;
    final current = _progress[key] ?? saved;
    final status = current?['status'] as String? ?? 'not_started';
    final score = _scoreControllers.putIfAbsent(key, () => TextEditingController(text: current?['score'] == null ? '' : '${current!['score']}'));

    void update(String newStatus, String scoreText) => _changed(() {
          _progress[key] = {'status': newStatus, 'score': double.tryParse(scoreText.trim())};
        });

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Expanded(child: Text(s.name, style: const TextStyle(color: brandInk), overflow: TextOverflow.ellipsis)),
        DropdownButton<String>(
          value: status,
          isDense: true,
          items: const [
            DropdownMenuItem(value: 'not_started', child: Text('Not started')),
            DropdownMenuItem(value: 'in_progress', child: Text('In progress')),
            DropdownMenuItem(value: 'completed', child: Text('Completed')),
          ],
          onChanged: _readOnly ? null : (v) => update(v!, score.text),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: TextField(
            controller: score,
            readOnly: _readOnly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true, hintText: 'Score', suffixText: '%', border: OutlineInputBorder()),
            onChanged: (v) {
              final n = double.tryParse(v.trim());
              if (v.trim().isEmpty || (n != null && n >= 0 && n <= 100)) update(status, v);
            },
          ),
        ),
      ]),
    );
  }
}
