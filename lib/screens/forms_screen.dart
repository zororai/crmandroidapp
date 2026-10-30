import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/repository.dart';
import 'form_fill_screen.dart';

// Kobo-style "Fill form": the CRM forms assigned to this user, downloaded
// for offline use. Uploading finalized submissions goes through the shared
// Sync Now on the home screen, alongside attendances and profiles.
class FormsScreen extends StatefulWidget {
  const FormsScreen({super.key});

  @override
  State<FormsScreen> createState() => _FormsScreenState();
}

class _FormsScreenState extends State<FormsScreen> {
  final _repo = Repository();
  List<Map<String, dynamic>> _forms = [];
  final _counts = <int, Map<String, int>>{};
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load(downloadIfEmpty: true);
  }

  Future<void> _load({bool downloadIfEmpty = false}) async {
    final forms = await _repo.getForms();
    for (final f in forms) {
      final id = f['assignmentId'] as int;
      _counts[id] = await _repo.submissionCounts(id);
    }
    if (!mounted) return;
    setState(() => _forms = forms);
    if (forms.isEmpty && downloadIfEmpty) _download();
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final count = await _repo.downloadForms();
      _showMessage(count == 0 ? 'No forms are assigned to you in the CRM yet.' : 'Downloaded $count form(s).');
    } catch (e) {
      _showMessage('Could not download forms — check your connection. ($e)');
    } finally {
      if (mounted) setState(() => _downloading = false);
      _load();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openForm(Map<String, dynamic> form) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FormSubmissionsScreen(form: form)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Collection'),
        actions: [
          IconButton(
            tooltip: 'Download forms from the CRM',
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_download_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _download,
        child: _forms.isEmpty
            ? ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _downloading
                          ? 'Downloading forms…'
                          : 'No forms downloaded.\nTap the download button to get the forms assigned to you in the CRM.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _forms.length,
                itemBuilder: (context, i) => _buildFormCard(_forms[i]),
              ),
      ),
    );
  }

  Widget _buildFormCard(Map<String, dynamic> form) {
    final counts = _counts[form['assignmentId'] as int] ?? const {};
    final subtitle = [
      if (form['projectName'] != null) form['projectName'],
      if (form['versionLabel'] != null) form['versionLabel'],
      if (form['dueDate'] != null) 'Due ${form['dueDate']}',
    ].join(' · ');

    return Card(
      child: ListTile(
        leading: const Icon(Icons.assignment_outlined),
        title: Text(form['formName'] as String? ?? 'Untitled form'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle.isNotEmpty) Text(subtitle),
            const SizedBox(height: 4),
            _StatusCounts(counts: counts),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openForm(form),
      ),
    );
  }
}

// One form: start a new submission, or open an existing draft / queued /
// rejected / synced one.
class FormSubmissionsScreen extends StatefulWidget {
  const FormSubmissionsScreen({super.key, required this.form});

  final Map<String, dynamic> form;

  @override
  State<FormSubmissionsScreen> createState() => _FormSubmissionsScreenState();
}

class _FormSubmissionsScreenState extends State<FormSubmissionsScreen> {
  final _repo = Repository();
  List<Map<String, dynamic>> _submissions = [];

  int get _assignmentId => widget.form['assignmentId'] as int;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _repo.getSubmissions(_assignmentId);
    if (mounted) setState(() => _submissions = rows);
  }

  Future<void> _open([Map<String, dynamic>? submission]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FormFillScreen(form: widget.form, submission: submission)),
    );
    _load();
  }

  Future<void> _delete(Map<String, dynamic> submission) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this submission?'),
        content: const Text('It has not been uploaded to the CRM and will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.deleteSubmission(submission['submissionUid'] as String);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final description = widget.form['formDescription'] as String?;

    return Scaffold(
      appBar: AppBar(title: Text(widget.form['formName'] as String? ?? 'Form')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add),
        label: const Text('New submission'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          if (description != null && description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(description, style: const TextStyle(color: Colors.grey)),
            ),
          if (_submissions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('No submissions yet. Tap "New submission" to start.', textAlign: TextAlign.center),
            ),
          for (final s in _submissions) _buildSubmissionTile(s),
        ],
      ),
    );
  }

  Widget _buildSubmissionTile(Map<String, dynamic> s) {
    final status = s['status'] as String;
    final updated = DateTime.tryParse(s['updatedAt'] as String? ?? '');

    return Card(
      child: ListTile(
        leading: _statusIcon(status),
        title: Text(_statusLabel(status)),
        subtitle: Text([
          if (updated != null) DateFormat('d MMM yyyy, HH:mm').format(updated),
          if (status == 'failed' && s['errorMessage'] != null) s['errorMessage'],
        ].join('\n')),
        isThreeLine: status == 'failed',
        trailing: status == 'synced'
            ? null
            : IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(s),
              ),
        onTap: () => _open(s),
      ),
    );
  }
}

String _statusLabel(String status) => switch (status) {
      'draft' => 'Draft',
      'ready' => 'Finalized — waiting to sync',
      'synced' => 'Sent to CRM',
      'failed' => 'Rejected by CRM — needs correction',
      _ => status,
    };

Widget _statusIcon(String status) => switch (status) {
      'draft' => const Icon(Icons.edit_note, color: Colors.grey),
      'ready' => const Icon(Icons.schedule, color: Colors.orange),
      'synced' => const Icon(Icons.cloud_done_outlined, color: Colors.green),
      'failed' => const Icon(Icons.error_outline, color: Colors.red),
      _ => const Icon(Icons.help_outline),
    };

class _StatusCounts extends StatelessWidget {
  const _StatusCounts({required this.counts});

  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if ((counts['draft'] ?? 0) > 0) '${counts['draft']} draft',
      if ((counts['ready'] ?? 0) > 0) '${counts['ready']} to sync',
      if ((counts['failed'] ?? 0) > 0) '${counts['failed']} rejected',
      if ((counts['synced'] ?? 0) > 0) '${counts['synced']} sent',
    ];
    return Text(parts.isEmpty ? 'No submissions yet' : parts.join(' · '), style: const TextStyle(fontSize: 12));
  }
}
