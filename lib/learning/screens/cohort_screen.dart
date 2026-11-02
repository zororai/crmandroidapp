import 'package:flutter/material.dart';

import '../../db/repository.dart';
import '../../theme/brand_colors.dart';
import '../db/learning_store.dart';
import '../models/learning_models.dart';
import '../widgets/learning_widgets.dart';
import 'course_editor_screen.dart';
import 'enrol_students_screen.dart';
import 'session_register_screen.dart';
import 'student_progress_screen.dart';

// One course/class: its sessions (with what has been recorded), its students
// and the topics. "Teach a session" opens the register, where attendance,
// topics taught and each student's assessment are recorded.
class CohortScreen extends StatefulWidget {
  const CohortScreen({super.key, required this.cohortUuid, this.startOnStudents = false});

  final String cohortUuid;
  final bool startOnStudents;

  @override
  State<CohortScreen> createState() => _CohortScreenState();
}

class _CohortScreenState extends State<CohortScreen> {
  final _repo = Repository();
  LearningCohort? _cohort;
  List<LocalSessionRecord> _local = [];
  bool _awaitingSetup = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await LearningStore.open();
    final userId = (await _repo.getCurrentUser())?['userId'] as int? ?? 0;
    final cohort = await store.cohort(widget.cohortUuid);
    final local = await store.records(ownerUserId: userId, cohortUuid: widget.cohortUuid);
    final awaiting = (await store.cohortsAwaitingSetup(userId)).contains(widget.cohortUuid);
    if (mounted) {
      setState(() {
        _cohort = cohort;
        _local = local;
        _awaitingSetup = awaiting;
      });
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  Future<void> _openRegister({PlannedSession? session, LocalSessionRecord? local, Map<String, dynamic>? server}) =>
      _push(SessionRegisterScreen(cohortUuid: widget.cohortUuid, session: session, local: local, serverRecord: server));

  @override
  Widget build(BuildContext context) {
    final c = _cohort;
    if (c == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final noStudents = c.roster.where((s) => s.isActive).isEmpty;
    return DefaultTabController(
      length: 3,
      initialIndex: widget.startOnStudents ? 1 : 0,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F6F3),
        appBar: AppBar(
          title: Text(c.courseTitle.isEmpty ? c.name : c.courseTitle),
          backgroundColor: const Color(0xFFF7F6F3),
          surfaceTintColor: Colors.transparent,
          actions: [
            if (c.canEditCourse)
              IconButton(tooltip: 'Edit course and topics', icon: const Icon(Icons.edit_outlined), onPressed: () => _push(CourseEditorScreen(cohort: c))),
          ],
          bottom: TabBar(tabs: [
            const Tab(text: 'Sessions'),
            Tab(text: 'Students (${c.roster.where((s) => s.isActive).length})'),
            Tab(text: 'Topics (${c.topics.length})'),
          ]),
        ),
        floatingActionButton: Builder(
          builder: (context) {
            final tab = DefaultTabController.of(context);
            return AnimatedBuilder(
              animation: tab,
              builder: (context, _) => tab.index == 1 && c.canEnrol
                  ? FloatingActionButton.extended(
                      onPressed: () => _push(EnrolStudentsScreen(cohortUuid: c.uuid)),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Add students'),
                    )
                  : FloatingActionButton.extended(
                      onPressed: noStudents ? () => tab.animateTo(1) : () => _openRegister(),
                      icon: const Icon(Icons.co_present),
                      label: Text(noStudents ? 'Add students first' : 'Teach a session'),
                    ),
            );
          },
        ),
        body: Column(children: [
          if (_awaitingSetup)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: statusWarning.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: const Row(children: [
                Icon(Icons.cloud_upload_outlined, color: statusWarning),
                SizedBox(width: 10),
                Expanded(child: Text('Saved on this phone. It will upload to the CRM next time you are online.')),
              ]),
            ),
          Expanded(child: TabBarView(children: [_sessions(c), _students(c), _topics(c)])),
        ]),
      ),
    );
  }

  // ── Sessions ──

  Widget _sessions(LearningCohort c) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final unscheduled = _local.where((r) => r.cohortSessionId == null).toList();
    final p = c.progress;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (p.isNotEmpty) ...[_summary(c, p), const SizedBox(height: 16)],
          if (unscheduled.isNotEmpty) ...[
            const Text('Sessions taught', style: TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
            const SizedBox(height: 8),
            for (final r in unscheduled) _sessionTile(c, date: r.heldOn, title: _topicsTitle(c, r.topics) ?? 'Session', local: r),
            const SizedBox(height: 16),
          ],
          if (c.sessions.isNotEmpty) ...[
            const Text('Schedule', style: TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
            const SizedBox(height: 8),
            for (final s in c.sessions)
              _sessionTile(
                c,
                date: s.date,
                title: c.plannedTopic(s)?.title ?? (s.isAdHoc ? 'Session' : 'Scheduled session'),
                time: s.startTime == null ? null : '${s.startTime}${s.endTime != null ? '–${s.endTime}' : ''}',
                session: s,
                local: _local.where((r) => r.cohortSessionId == s.id).firstOrNull,
                server: c.serverRecords.where((r) => r['cohort_session_id'] == s.id).firstOrNull,
                overdue: s.status == 'scheduled' && s.date.compareTo(today) < 0,
                future: s.date.compareTo(today) > 0,
              ),
          ],
          if (c.sessions.isEmpty && unscheduled.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No sessions yet. Tap "Teach a session" when you start teaching.', textAlign: TextAlign.center, style: TextStyle(color: inkMuted)),
            ),
        ],
      ),
    );
  }

  String? _topicsTitle(LearningCohort c, List<Map<String, dynamic>> topics) {
    final titles = [for (final t in topics) c.topic(t['topic_client_uuid'] as String?)?.title].whereType<String>().toList();
    return titles.isEmpty ? null : titles.join(', ');
  }

  Widget _summary(LearningCohort c, Map<String, dynamic> p) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: hairline)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk))),
              scheduleStatusPill(p['schedule_status'] as String?),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _figure('${p['topics_delivered'] ?? 0}/${p['topics_total'] ?? c.topics.length}', 'topics taught')),
              Expanded(child: _figure('${p['sessions_held'] ?? 0}', 'sessions held')),
              Expanded(child: _figure('${c.roster.where((s) => s.isActive && s.atRisk.isNotEmpty).length}', 'students at risk')),
            ]),
            for (final flag in ((p['at_risk'] as List?) ?? const []).cast<Map<String, dynamic>>())
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: statusWarning),
                  const SizedBox(width: 6),
                  Expanded(child: Text(riskLabel(flag), style: const TextStyle(fontSize: 13, color: brandInk))),
                ]),
              ),
          ],
        ),
      );

  Widget _figure(String value, String label) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: brandInk)),
          Text(label, style: const TextStyle(fontSize: 12, color: inkSecondary)),
        ],
      );

  Widget _sessionTile(
    LearningCohort c, {
    required String date,
    required String title,
    String? time,
    PlannedSession? session,
    LocalSessionRecord? local,
    Map<String, dynamic>? server,
    bool overdue = false,
    bool future = false,
  }) {
    final StatusPill pill;
    VoidCallback? onTap;
    if (local != null) {
      pill = switch (local.status) {
        RecordStatus.draft => const StatusPill(icon: Icons.edit_note, label: 'Draft', color: inkMuted),
        RecordStatus.finalized || RecordStatus.syncing => const StatusPill(icon: Icons.schedule, label: 'Waiting to send', color: statusWarning),
        RecordStatus.failed => const StatusPill(icon: Icons.error_outline, label: 'Needs fixing', color: statusCritical),
        RecordStatus.sent => const StatusPill(icon: Icons.cloud_done_outlined, label: 'Recorded', color: statusGood),
      };
      onTap = () => _openRegister(session: session, local: local);
    } else if (server != null) {
      pill = const StatusPill(icon: Icons.cloud_done_outlined, label: 'Recorded', color: statusGood);
      onTap = () => _openRegister(session: session, server: server);
    } else if (session?.status == 'cancelled') {
      pill = const StatusPill(icon: Icons.block, label: 'Cancelled', color: inkMuted);
    } else if (overdue) {
      pill = const StatusPill(icon: Icons.warning_amber_rounded, label: 'Not recorded', color: statusCritical);
      onTap = () => _openRegister(session: session);
    } else {
      pill = StatusPill(icon: Icons.event, label: future ? 'Upcoming' : 'Today', color: brandPurple);
      onTap = future ? null : () => _openRegister(session: session);
    }

    final marks = local?.attendance ?? ((server?['attendance'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final present = marks.where((m) => m['status'] == 'present' || m['status'] == 'late').length;
    final duration = local?.duration;

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: hairline)),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
        subtitle: Text(
          [
            formatDate(date),
            if (time != null) time,
            if (duration != null) formatDuration(duration),
            if (marks.isNotEmpty) '$present/${marks.length} attended',
          ].join(' · '),
          style: const TextStyle(color: inkSecondary),
        ),
        trailing: pill,
      ),
    );
  }

  // ── Students ──

  Widget _students(LearningCohort c) {
    final students = [...c.roster]..sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    if (students.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('No students yet.\nTap "Add students" to enrol your class.', textAlign: TextAlign.center, style: TextStyle(color: inkSecondary)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: students.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final s = students[i];
        return Card(
          elevation: 0,
          color: Colors.white,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: hairline)),
          child: ListTile(
            onTap: () => _push(StudentProgressScreen(cohort: c, student: s, localRecords: _local)),
            leading: CircleAvatar(
              backgroundColor: brandPurple.withValues(alpha: 0.12),
              child: Text(s.name.isEmpty ? '?' : s.name[0], style: const TextStyle(color: brandPurple, fontWeight: FontWeight.bold)),
            ),
            title: Text(s.name, style: TextStyle(fontWeight: FontWeight.w600, color: s.isActive ? brandInk : inkMuted)),
            subtitle: Text(
              [if (s.studentRef != null) s.studentRef!, if (!s.isActive) s.status, if (s.attendancePct != null) 'Attendance ${pct(s.attendancePct)}'].join(' · '),
              style: const TextStyle(color: inkSecondary),
            ),
            trailing: s.isActive && s.atRisk.isNotEmpty
                ? const StatusPill(icon: Icons.warning_amber_rounded, label: 'At risk', color: statusWarning)
                : s.eligibleForCompletion
                    ? const StatusPill(icon: Icons.workspace_premium_outlined, label: 'Eligible', color: statusGood)
                    : const Icon(Icons.chevron_right, color: inkMuted),
          ),
        );
      },
    );
  }

  // ── Topics ──

  Widget _topics(LearningCohort c) {
    // Taught = covered fully in any session (CRM or this phone).
    final full = <String>{};
    final partial = <String>{};
    void add(List<Map<String, dynamic>> topics) {
      for (final t in topics) {
        final uuid = t['topic_client_uuid'] as String?;
        if (uuid != null) (t['coverage'] == 'full' ? full : partial).add(uuid);
      }
    }

    for (final r in c.serverRecords) {
      add(((r['topics'] as List?) ?? const []).cast<Map<String, dynamic>>());
    }
    for (final r in _local) {
      add(r.topics);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        for (final t in c.topics)
          Card(
            elevation: 0,
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: hairline)),
            child: ListTile(
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: full.contains(t.uuid) ? statusGood.withValues(alpha: 0.15) : brandPurple.withValues(alpha: 0.08),
                child: full.contains(t.uuid)
                    ? const Icon(Icons.check, size: 18, color: statusGood)
                    : Text('${t.position}', style: const TextStyle(fontSize: 13, color: brandPurple)),
              ),
              title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
              subtitle: Text(
                [
                  '${t.plannedSessions} session${t.plannedSessions == 1 ? '' : 's'} planned',
                  if (t.isAssessed) 'Assessed',
                  if (full.contains(t.uuid)) 'Taught' else if (partial.contains(t.uuid)) 'Partly taught' else 'Not taught yet',
                ].join(' · '),
                style: const TextStyle(color: inkSecondary),
              ),
            ),
          ),
        if (c.canEditCourse)
          TextButton.icon(onPressed: () => _push(CourseEditorScreen(cohort: c)), icon: const Icon(Icons.add), label: const Text('Add or edit topics')),
      ],
    );
  }
}
