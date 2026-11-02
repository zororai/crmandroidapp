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
import 'performance_screen.dart';

// "My courses": the cohorts this facilitator runs, usable offline from the
// last download. Pull down to refresh from the CRM.
class CohortsScreen extends StatefulWidget {
  const CohortsScreen({super.key});

  @override
  State<CohortsScreen> createState() => _CohortsScreenState();
}

class _CohortsScreenState extends State<CohortsScreen> {
  final _repo = Repository();
  List<LearningCohort> _cohorts = [];
  final _unsent = <int, int>{};
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
    _unsent
      ..clear()
      ..addAll({
        for (final c in cohorts)
          c.id: records.where((r) => r.cohortId == c.id && r.status != RecordStatus.sent).length,
      });
    if (!mounted) return;
    setState(() {
      _cohorts = cohorts;
      _loading = false;
    });
    if (cohorts.isEmpty && refreshIfEmpty) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final sync = await SyncRunner.learningSync();
      if (sync == null) throw AuthExpiredException();
      await sync.refreshCohorts();
      // Push anything waiting while we're online anyway.
      SyncCoordinator.instance.sync();
    } on AuthExpiredException {
      if (mounted) await promptReauth(context);
    } on ApiException catch (e) {
      _showMessage(e.transient ? 'Can\'t reach the server — showing the cohorts already on this device.' : e.message);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(
        title: const Text('My Courses'),
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
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _cohorts.isEmpty
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _refreshing
                            ? 'Downloading your cohorts…'
                            : 'No cohorts on this device.\nPull down to download the cohorts you facilitate in the CRM.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: inkMuted),
                      ),
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
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
    final atRisk = c.roster.where((s) => s.isActive && s.atRisk.isNotEmpty).length;
    final unsent = _unsent[c.id] ?? 0;

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: hairline)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(CohortScreen(cohortId: c.id)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: brandInk)),
              Text([c.courseTitle, if (c.venue != null) c.venue].join(' · '), style: const TextStyle(color: inkSecondary)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: (delivered ?? 0) / 100, minHeight: 8, backgroundColor: brandPurple.withValues(alpha: 0.12)),
                  ),
                ),
                const SizedBox(width: 10),
                Text('${pct(delivered)} of syllabus', style: const TextStyle(fontSize: 12, color: inkSecondary)),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: [
                scheduleStatusPill(progress['schedule_status'] as String?),
                if (atRisk > 0) StatusPill(icon: Icons.warning_amber_rounded, label: '$atRisk at risk', color: statusWarning),
                if (unsent > 0) StatusPill(icon: Icons.cloud_upload_outlined, label: '$unsent not sent', color: statusWarning),
              ]),
              if (next != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  const Icon(Icons.event, size: 16, color: inkMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Next: ${formatDate(next.date)}${next.startTime != null ? ' at ${next.startTime}' : ''}'
                      '${c.topic(next.plannedTopicId) != null ? ' · ${c.topic(next.plannedTopicId)!.title}' : ''}',
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
