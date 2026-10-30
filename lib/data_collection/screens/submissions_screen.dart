import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../db/repository.dart';
import '../db/data_collection_store.dart';
import '../media/media_files.dart';
import '../models/submission.dart';
import '../sync/sync_coordinator.dart';
import 'form_fill_screen.dart';
import 'sync_ui.dart';

const _tabs = [
  ('Drafts', {SubmissionStatus.draft}),
  ('Ready to send', {SubmissionStatus.finalized, SubmissionStatus.syncing}),
  ('Sent', {SubmissionStatus.sent}),
  ('Failed', {SubmissionStatus.failed}),
];

// This user's submissions by state. Drafts, unsent and failed ones open for
// editing; sent ones open read-only.
class SubmissionsScreen extends StatefulWidget {
  const SubmissionsScreen({super.key});

  @override
  State<SubmissionsScreen> createState() => _SubmissionsScreenState();
}

class _SubmissionsScreenState extends State<SubmissionsScreen> {
  final _repo = Repository();
  late DataCollectionStore _store;
  int _userId = 0;
  final _lists = <int, List<Submission>>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _store = await DataCollectionStore.open();
    _userId = (await _repo.getCurrentUser())?['userId'] as int? ?? 0;
    for (var i = 0; i < _tabs.length; i++) {
      _lists[i] = await _store.submissions(ownerUserId: _userId, statuses: _tabs[i].$2);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(Submission s) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FormFillScreen(formId: s.formId, formVersion: s.formVersion, formTitle: s.formTitle, submissionUuid: s.clientUuid),
    ));
    _load();
  }

  Future<void> _delete(Submission s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this submission?'),
        content: const Text('It has not been sent to the CRM and will be lost, with its photos.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final path in await _store.deleteSubmission(s.clientUuid)) {
      await const MediaFiles().delete(path);
    }
    _load();
  }

  Future<void> _retry(Submission s) async {
    await _store.requeue(s.clientUuid, DateTime.now());
    await _sendNow();
  }

  Future<void> _sendNow() async {
    final report = await SyncCoordinator.instance.sync(force: true);
    if (mounted) await showSyncReport(context, report);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My Submissions'),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              for (var i = 0; i < _tabs.length; i++) Tab(text: '${_tabs[i].$1} (${_lists[i]?.length ?? 0})'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [for (var i = 0; i < _tabs.length; i++) _buildList(i)]),
      ),
    );
  }

  Widget _buildList(int tab) {
    final items = _lists[tab] ?? const [];
    final isReadyTab = tab == 1;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (isReadyTab && items.isNotEmpty)
            ValueListenableBuilder<bool>(
              valueListenable: SyncCoordinator.instance.running,
              builder: (context, running, _) => FilledButton.icon(
                onPressed: running ? null : _sendNow,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(running ? 'Sending…' : 'Send now'),
              ),
            ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(_emptyText(tab), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
            ),
          for (final s in items) _buildTile(s),
        ],
      ),
    );
  }

  String _emptyText(int tab) => switch (tab) {
        0 => 'No drafts.',
        1 => 'Nothing waiting to send.',
        2 => 'Nothing sent in the last few weeks.',
        _ => 'No failed submissions.',
      };

  Widget _buildTile(Submission s) {
    final when = DateFormat('d MMM yyyy, HH:mm').format(s.sentAt ?? s.finalizedAt ?? s.updatedAt);
    final retrying = s.status == SubmissionStatus.finalized && s.errorReason != null;

    return Card(
      child: ListTile(
        title: Text(s.formTitle),
        subtitle: Text([
          when,
          if (s.status == SubmissionStatus.syncing) 'Sending…',
          if (retrying) 'Will retry: ${s.errorReason}',
          if (s.status == SubmissionStatus.failed) s.errorReason ?? 'Rejected by the server.',
        ].join('\n')),
        isThreeLine: s.status == SubmissionStatus.failed || retrying,
        onTap: () => _open(s),
        trailing: switch (s.status) {
          SubmissionStatus.failed => TextButton(onPressed: () => _retry(s), child: const Text('Retry')),
          SubmissionStatus.draft || SubmissionStatus.finalized => IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(s),
            ),
          _ => null,
        },
      ),
    );
  }
}
