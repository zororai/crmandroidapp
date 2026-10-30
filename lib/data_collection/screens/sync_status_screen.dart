import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../db/repository.dart';
import '../db/data_collection_store.dart';
import '../models/submission.dart';
import '../sync/background_sync.dart';
import '../sync/sync_coordinator.dart';
import 'sync_ui.dart';

class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  final _repo = Repository();
  Map<SubmissionStatus, int> _counts = {};
  List<Map<String, dynamic>> _runs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await DataCollectionStore.open();
    final userId = (await _repo.getCurrentUser())?['userId'] as int? ?? 0;
    final counts = await store.statusCounts(userId);
    final runs = await store.recentRuns();
    if (mounted) {
      setState(() {
        _counts = counts;
        _runs = runs;
      });
    }
  }

  Future<void> _syncNow() async {
    final report = await SyncCoordinator.instance.sync(force: true);
    if (mounted) await showSyncReport(context, report);
    _load();
  }

  String _formatTime(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    return t == null ? '—' : DateFormat('d MMM yyyy, HH:mm').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final last = _runs.isEmpty ? null : _runs.first;
    final report = SyncCoordinator.instance.lastReport.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync Status')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Last sync: ${_formatTime(last?['finishedAt'] as String?)}', style: Theme.of(context).textTheme.titleMedium),
                    if (last?['error'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Problem: ${last!['error']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    if (report?.authExpired ?? false)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton(onPressed: () => promptReauth(context).then((_) => _load()), child: const Text('Log in again')),
                      ),
                    const SizedBox(height: 12),
                    _countRow('Drafts', _counts[SubmissionStatus.draft]),
                    _countRow('Waiting to send', (_counts[SubmissionStatus.finalized] ?? 0) + (_counts[SubmissionStatus.syncing] ?? 0)),
                    _countRow('Failed (need correction)', _counts[SubmissionStatus.failed]),
                    _countRow('Sent (kept on device)', _counts[SubmissionStatus.sent]),
                    const SizedBox(height: 12),
                    Text(
                      BackgroundSync.supported
                          ? 'Sends automatically when online, including in the background.'
                          : 'Sends automatically while the app is open and online.',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<bool>(
              valueListenable: SyncCoordinator.instance.running,
              builder: (context, running, _) => FilledButton.icon(
                onPressed: running ? null : _syncNow,
                icon: running
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: Text(running ? 'Syncing…' : 'Sync now'),
              ),
            ),
            const SizedBox(height: 24),
            Text('Recent syncs', style: Theme.of(context).textTheme.titleMedium),
            if (_runs.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('No syncs yet.', style: TextStyle(color: Colors.grey))),
            for (final r in _runs)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(r['error'] == null ? Icons.check_circle_outline : Icons.error_outline,
                    color: r['error'] == null ? Colors.green : Colors.orange),
                title: Text(_formatTime(r['finishedAt'] as String?)),
                subtitle: Text([
                  'Sent ${r['sent']}',
                  if ((r['failed'] as int? ?? 0) > 0) 'failed ${r['failed']}',
                  'pending ${r['pending']}',
                  if (r['error'] != null) '${r['error']}',
                ].join(' · ')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _countRow(String label, int? count) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [Expanded(child: Text(label)), Text('${count ?? 0}', style: const TextStyle(fontWeight: FontWeight.bold))]),
      );
}
