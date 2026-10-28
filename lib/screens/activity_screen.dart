import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../db/repository.dart';
import 'capture_screen.dart';
import 'login_screen.dart';
import 'profile_screen.dart';

// The "New attendance register" screen — captures the paper form's header
// row (activity name, date, compiled by, reviewed by), then hands off to
// CaptureScreen to add each beneficiary row underneath it.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final _repo = Repository();
  final _nameController = TextEditingController();
  final _dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _compiledByController = TextEditingController();
  final _reviewedByController = TextEditingController();

  String _loggedInAs = '';
  int _pendingCount = 0;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final user = await _repo.getCurrentUser();
    final pending = await _repo.pendingSyncCount();
    setState(() {
      _loggedInAs = user != null ? 'Logged in as ${user['name']}' : '';
      _pendingCount = pending;
    });
  }

  Future<void> _startActivity() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an activity name')));
      return;
    }

    final uuid = await _repo.startActivity(
      activityName: name,
      activityDate: _dateController.text.trim(),
      compiledBy: _compiledByController.text.trim().isEmpty ? null : _compiledByController.text.trim(),
      reviewedBy: _reviewedByController.text.trim().isEmpty ? null : _reviewedByController.text.trim(),
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CaptureScreen(activityUuid: uuid, activityName: name)),
    );
    _loadState(); // refresh pending count after returning
  }

  Future<void> _openProfiling() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
    _loadState(); // refresh pending count after returning
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await _repo.syncPending();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sync complete.')));
      }
    } catch (e) {
      // Typically no connectivity — not an error the user needs to see in
      // detail, just that it didn't go through this time.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync failed (will retry later): $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
      _loadState();
    }
  }

  Future<void> _logout() async {
    await _repo.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Beneficiary Attendance')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loggedInAs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_loggedInAs, style: const TextStyle(color: Colors.grey)),
              ),
            const Text('New Attendance Register', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Activity name')),
            const SizedBox(height: 8),
            TextField(controller: _dateController, decoration: const InputDecoration(labelText: 'Date (yyyy-MM-dd)')),
            const SizedBox(height: 8),
            TextField(controller: _compiledByController, decoration: const InputDecoration(labelText: 'Compiled by')),
            const SizedBox(height: 8),
            TextField(controller: _reviewedByController, decoration: const InputDecoration(labelText: 'Reviewed by')),
            const SizedBox(height: 16),
            FilledButton(onPressed: _startActivity, child: const Text('Start Capturing Beneficiaries')),
            const SizedBox(height: 24),
            const Text('Beneficiary Profiling', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: _openProfiling, child: const Text('New Beneficiary Profile')),
            const SizedBox(height: 24),
            Text('Pending sync: $_pendingCount'),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _syncing ? null : _syncNow,
              child: _syncing ? const Text('Syncing...') : const Text('Sync Now'),
            ),
            const SizedBox(height: 24),
            TextButton(onPressed: _logout, child: const Text('Log Out')),
          ],
        ),
      ),
    );
  }
}
