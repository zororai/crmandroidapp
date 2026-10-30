import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../db/repository.dart';
import '../api/data_collection_api.dart';
import '../db/data_collection_store.dart';
import '../models/submission.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_runner.dart';
import 'form_fill_screen.dart';
import 'submissions_screen.dart';
import 'sync_status_screen.dart';
import 'sync_ui.dart';

// The forms assigned to this user in the CRM, usable offline from the
// cached schemas. Pull down to fetch the list and any newer versions.
class FormsListScreen extends StatefulWidget {
  const FormsListScreen({super.key});

  @override
  State<FormsListScreen> createState() => _FormsListScreenState();
}

class _FormsListScreenState extends State<FormsListScreen> {
  final _repo = Repository();
  List<Map<String, dynamic>> _forms = [];
  final _statusCounts = <int, Map<SubmissionStatus, int>>{};
  final _collected = <int, Map<String, int>>{};
  bool _loading = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _load(refreshIfEmpty: true);
  }

  Future<void> _load({bool refreshIfEmpty = false}) async {
    final store = await DataCollectionStore.open();
    final userId = (await _repo.getCurrentUser())?['userId'] as int? ?? 0;
    final forms = await store.forms();
    final now = DateTime.now();
    for (final f in forms) {
      final id = f['formId'] as int;
      _statusCounts[id] = await store.statusCounts(userId, formId: id);
      _collected[id] = await store.collectedCounts(userId, id, now);
    }
    if (!mounted) return;
    setState(() {
      _forms = forms;
      _loading = false;
    });
    if (forms.isEmpty && refreshIfEmpty) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final downloaded = await SyncRunner.refreshForms();
      _showMessage(downloaded == 0 ? 'Forms are up to date.' : 'Downloaded $downloaded form update(s).');
    } on AuthExpiredException {
      if (mounted) await promptReauth(context);
    } on ApiException catch (e) {
      _showMessage(e.transient ? 'Can\'t reach the server — using the forms already on this device.' : e.message);
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
      appBar: AppBar(
        title: const Text('Data Collection'),
        actions: [
          IconButton(
            tooltip: 'My submissions',
            icon: const Icon(Icons.inbox_outlined),
            onPressed: () => _open(const SubmissionsScreen()),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: SyncCoordinator.instance.running,
            builder: (context, running, _) => IconButton(
              tooltip: 'Sync status',
              icon: running
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              onPressed: () => _open(const SyncStatusScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _forms.isEmpty
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _refreshing
                            ? 'Downloading forms…'
                            : 'No forms on this device.\nPull down to download the forms assigned to you in the CRM.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _forms.length,
                    itemBuilder: (context, i) => _buildCard(_forms[i]),
                  ),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> form) {
    final id = form['formId'] as int;
    final cached = form['cachedVersion'] as String?;
    final latest = form['latestVersion'] as String?;
    final updateAvailable = cached != null && (cached != latest || form['cachedChecksum'] != form['latestChecksum']);
    final updatedAt = DateTime.tryParse(form['updatedAt'] as String? ?? '');
    final counts = _statusCounts[id] ?? const {};
    final collected = _collected[id] ?? const {};

    final queue = [
      if ((counts[SubmissionStatus.draft] ?? 0) > 0) '${counts[SubmissionStatus.draft]} draft',
      if ((counts[SubmissionStatus.finalized] ?? 0) + (counts[SubmissionStatus.syncing] ?? 0) > 0)
        '${(counts[SubmissionStatus.finalized] ?? 0) + (counts[SubmissionStatus.syncing] ?? 0)} unsent',
      if ((counts[SubmissionStatus.failed] ?? 0) > 0) '${counts[SubmissionStatus.failed]} failed',
    ];

    return Card(
      child: ListTile(
        leading: const Icon(Icons.assignment_outlined),
        title: Text(form['title'] as String? ?? 'Untitled form'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text([
              if (cached != null) 'Version $cached' else 'Not downloaded yet',
              if (updatedAt != null) 'updated ${DateFormat('d MMM yyyy').format(updatedAt)}',
            ].join(' · ')),
            if (queue.isNotEmpty) Text(queue.join(' · ')),
            Text(
              'Today ${collected['today'] ?? 0} · This week ${collected['week'] ?? 0} · Total ${collected['total'] ?? 0}',
              style: const TextStyle(fontSize: 12),
            ),
            if (updateAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: ActionChip(
                  avatar: const Icon(Icons.system_update_alt, size: 16),
                  label: const Text('Update available'),
                  onPressed: _refreshing ? null : _refresh,
                ),
              ),
          ],
        ),
        trailing: const Icon(Icons.add_circle_outline),
        enabled: cached != null,
        onTap: cached == null
            ? null
            : () => _open(FormFillScreen(formId: id, formVersion: cached, formTitle: form['title'] as String? ?? '')),
      ),
    );
  }
}
