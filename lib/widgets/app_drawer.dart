import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../data_collection/config.dart';
import '../data_collection/db/data_collection_store.dart';
import '../data_collection/models/submission.dart';
import '../data_collection/screens/forms_list_screen.dart';
import '../data_collection/screens/submissions_screen.dart';
import '../data_collection/screens/sync_status_screen.dart';
import '../db/repository.dart';
import '../screens/profile_screen.dart';
import '../theme/brand_colors.dart';

// The app's hamburger menu, opened from the home screen. Pushes each screen
// on top of home, so the back button always leads home again.
class AppDrawer extends StatefulWidget {
  const AppDrawer({super.key, required this.onLogout, this.onReturn});

  final Future<void> Function() onLogout;
  final VoidCallback? onReturn; // e.g. refresh the home screen's pending count

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  final _repo = Repository();
  String _name = '';
  String _email = '';
  int _needsAttention = 0; // drafts + failed submissions
  int _pending = 0; // everything waiting to sync

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Built fresh each time the drawer opens, so badges are always current.
  Future<void> _load() async {
    final user = await _repo.getCurrentUser();
    final userId = user?['userId'] as int? ?? 0;
    final counts = await (await DataCollectionStore.open()).statusCounts(userId);
    final pending = await _repo.pendingSyncCount();
    if (!mounted) return;
    setState(() {
      _name = user?['name'] as String? ?? '';
      _email = user?['email'] as String? ?? '';
      _needsAttention = (counts[SubmissionStatus.draft] ?? 0) + (counts[SubmissionStatus.failed] ?? 0);
      _pending = pending;
    });
  }

  // Destination order matches the NavigationDrawerDestinations below.
  Future<void> _select(int index) async {
    final navigator = Navigator.of(context);
    final onReturn = widget.onReturn;
    navigator.pop(); // close the drawer first, so the transition is one smooth slide

    final Widget? screen = switch (index) {
      1 => const ProfileScreen(),
      2 => const FormsListScreen(),
      3 => const SubmissionsScreen(),
      4 => const SyncStatusScreen(),
      _ => null,
    };
    if (index == 5) {
      await _confirmLogout(navigator.context);
      return;
    }
    if (screen == null) return; // 0 = home, already here
    await navigator.push(MaterialPageRoute(builder: (_) => screen));
    onReturn?.call();
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final pending = _pending;
    final onLogout = widget.onLogout;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: Text(pending > 0
            ? 'You have $pending item(s) not yet sent. They stay safely on this device and will be sent next time you log in.'
            : 'You can log back in at any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
        ],
      ),
    );
    if (confirmed == true) await onLogout();
  }

  Widget _badge(IconData icon, int count, {Color? color}) => Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: color,
        child: Icon(icon),
      );

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 16, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: Colors.black.withValues(alpha: 0.45)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return NavigationDrawer(
      selectedIndex: 0,
      onDestinationSelected: _select,
      children: [
        _Header(name: _name, email: _email),
        _sectionLabel('Capture'),
        const NavigationDrawerDestination(
          icon: Icon(Icons.how_to_reg_outlined),
          selectedIcon: Icon(Icons.how_to_reg),
          label: Text('Attendance register'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.badge_outlined),
          selectedIcon: Icon(Icons.badge),
          label: Text('Beneficiary profile'),
        ),
        _sectionLabel('Data collection'),
        const NavigationDrawerDestination(
          icon: Icon(Icons.assignment_outlined),
          selectedIcon: Icon(Icons.assignment),
          label: Text('Fill forms'),
        ),
        NavigationDrawerDestination(
          icon: _badge(Icons.inbox_outlined, _needsAttention),
          selectedIcon: _badge(Icons.inbox, _needsAttention),
          label: const Text('My submissions'),
        ),
        NavigationDrawerDestination(
          icon: _badge(Icons.sync, _pending, color: brandOrange),
          label: const Text('Sync status'),
        ),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 28, vertical: 12), child: Divider()),
        const NavigationDrawerDestination(
          icon: Icon(Icons.logout),
          label: Text('Log out'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 16, 24),
          child: Text('Version $appVersion', style: TextStyle(fontSize: 12, color: Colors.black.withValues(alpha: 0.4))),
        ),
      ],
    );
  }
}

// Orange → purple, the logo's colours, with the logo, the user and the server.
class _Header extends StatelessWidget {
  const _Header({required this.name, required this.email});

  final String name;
  final String email;

  @override
  Widget build(BuildContext context) {
    final server = ApiClient.baseUrl?.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/api/?$'), '');

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(colors: [brandOrange, brandPurple], begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: brandPurple.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Image.asset('assets/images/logo.png', height: 44),
          ),
          const SizedBox(height: 16),
          Text(
            name.isEmpty ? 'Welcome' : name,
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (email.isNotEmpty)
            Text(email, style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (server != null && server.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.dns_outlined, size: 14, color: Colors.white),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(server, style: const TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}
