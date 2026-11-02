import 'package:flutter/material.dart';

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/screens/sync_ui.dart';
import '../../data_collection/sync/sync_coordinator.dart';
import '../../data_collection/sync/sync_runner.dart';
import '../../db/repository.dart';
import '../../theme/brand_colors.dart';
import '../db/learning_store.dart';
import '../models/learning_models.dart';
import '../widgets/learning_widgets.dart';
import 'cohort_screen.dart';
import 'course_editor_screen.dart';
import 'performance_screen.dart';

// Courses: the classes this teacher runs — set up here or in the CRM —
// usable offline. "New course" creates a course with its topics and the
// teacher's class on it.
class CohortsScreen extends StatefulWidget {
  const CohortsScreen({super.key});

  @override
  State<CohortsScreen> createState() => _CohortsScreenState();
}

class _CohortsScreenState extends State<CohortsScreen> {
  final _repo = Repository();
  List<LearningCohort> _cohorts = [];
  final _unsent = <String, int>{};
  Set<String> _awaitingSetup = {};
  bool _loading = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _load(refreshIfEmpty: true);
  }

  Future<void> _load({bool refreshIfEmpty = false}) async {
    final store = await LearningStore.open();
    final userId = (await _repo.getCurrentUser())?['userId'] as int? ?? 0;
    final cohorts = await store.cohorts(userId);
    final records = await store.records(ownerUserId: userId);
    final awaiting = await store.cohortsAwaitingSetup(userId);
    _unsent
      ..clear()
      ..addAll({for (final c in cohorts) c.uuid: records.where((r) => r.cohortUuid == c.uuid && r.status != RecordStatus.sent).length});
    if (!mounted) return;
    setState(() {
      _cohorts = cohorts;
      _awaitingSetup = awaiting;
      _loading = false;
    });
    if (cohorts.isEmpty && refreshIfEmpty) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final sync = await SyncRunner.learningSync();
      if (sync == null) throw AuthExpiredException();
      await sync.uploadSetup();
      await sync.refreshCohorts();
      SyncCoordinator.instance.sync(); // send any finished sessions too
    } on AuthExpiredException {
      if (mounted) await promptReauth(context);
    } on ApiException catch (e) {
      _showMessage(e.transient ? 'Can\'t reach the server — showing the courses on this device.' : e.message);
    } finally {
      if (mounted) setState(() => _refreshing = false);
      await _load();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  Future<void> _newCourse() async {
    final cohortUuid = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const CourseEditorScreen()));
    await _load();
    if (cohortUuid != null && mounted) {
      // Straight on to adding students.
      await _open(CohortScreen(cohortUuid: cohortUuid, startOnStudents: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(
        title: const Text('Courses'),
        backgroundColor: const Color(0xFFF7F6F3),
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'My performance',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => _open(const PerformanceScreen()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newCourse,
        icon: const Icon(Icons.add),
        label: const Text('New course'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _cohorts.isEmpty
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(children: [
                        const Icon(Icons.school_outlined, size: 48, color: inkMuted),
                        const SizedBox(height: 12),
                        Text(
                          _refreshing
                              ? 'Looking for your courses…'
                              : 'No courses yet.\nTap "New course" to set one up: its name, the topics you will teach, '
                                  'and the students in your class.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: inkSecondary),
                        ),
                      ]),
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    itemCount: _cohorts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => _card(_cohorts[i]),
                  ),
      ),
    );
  }

  Widget _card(LearningCohort c) {
    final progress = c.progress;
    final delivered = (progress['delivered_pct'] as num?)?.toDouble();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final next = c.sessions.where((s) => s.status == 'scheduled' && s.date.compareTo(today) >= 0).firstOrNull;
    final active = c.roster.where((s) => s.isActive).length;
    final atRisk = c.roster.where((s) => s.isActive && s.atRisk.isNotEmpty).length;
    final unsent = _unsent[c.uuid] ?? 0;
    final notUploaded = _awaitingSetup.contains(c.uuid);

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: hairline)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(CohortScreen(cohortUuid: c.uuid)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.courseTitle.isEmpty ? c.name : c.courseTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: brandInk)),
              Text([if (c.courseTitle.isNotEmpty && c.name != c.courseTitle) c.name, if (c.venue != null && c.venue!.isNotEmpty) c.venue, '$active student${active == 1 ? '' : 's'}', '${c.topics.length} topics'].join(' · '),
                  style: const TextStyle(color: inkSecondary)),
              if (delivered != null) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: delivered / 100, minHeight: 8, backgroundColor: brandPurple.withValues(alpha: 0.12)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${pct(delivered)} of topics taught', style: const TextStyle(fontSize: 12, color: inkSecondary)),
                ]),
              ],
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: [
                if (notUploaded) const StatusPill(icon: Icons.cloud_upload_outlined, label: 'Not uploaded yet', color: statusWarning),
                if (progress['schedule_status'] != null) scheduleStatusPill(progress['schedule_status'] as String?),
                if (atRisk > 0) StatusPill(icon: Icons.warning_amber_rounded, label: '$atRisk at risk', color: statusWarning),
                if (unsent > 0) StatusPill(icon: Icons.schedule, label: '$unsent session${unsent == 1 ? '' : 's'} not sent', color: statusWarning),
              ]),
              if (next != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.event, size: 16, color: inkMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Next: ${formatDate(next.date)}${next.startTime != null ? ' at ${next.startTime}' : ''}'
                      '${c.plannedTopic(next) != null ? ' · ${c.plannedTopic(next)!.title}' : ''}',
                      style: const TextStyle(fontSize: 13, color: inkSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
