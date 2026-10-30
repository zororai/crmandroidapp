import 'package:flutter/material.dart';

import '../../screens/login_screen.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_engine.dart';

// One wording for sync outcomes across the data collection screens.
String describeSyncReport(SyncReport r) {
  if (r.authExpired) return 'Your session expired. Log in again to send your forms.';
  if (r.skipped) return r.error ?? 'Nothing to sync.';
  if (r.error != null) return 'Sync incomplete: ${r.error} It will retry automatically.';
  final parts = [
    if (r.sent > 0) 'Sent ${r.sent} submission(s).',
    if (r.failed > 0) '${r.failed} need correction (see Failed).',
    if (r.pending > 0) '${r.pending} still waiting to send.',
  ];
  return parts.isEmpty ? 'Everything is up to date.' : parts.join(' ');
}

Future<void> showSyncReport(BuildContext context, SyncReport r) async {
  if (r.authExpired) {
    await promptReauth(context);
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeSyncReport(r))));
}

// The token has expired: offer to log in again over the current screen.
// Queued submissions are untouched either way. Returns true if the user
// logged back in (and a sync was started).
Future<bool> promptReauth(BuildContext context) async {
  final goToLogin = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Session expired'),
      content: const Text('Your unsent forms are safe on this device. Log in again to send them.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log in')),
      ],
    ),
  );
  if (goToLogin != true || !context.mounted) return false;

  final loggedIn = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const LoginScreen(reauth: true)),
  );
  if (loggedIn != true || !context.mounted) return false;

  final report = await SyncCoordinator.instance.sync(force: true);
  if (context.mounted) await showSyncReport(context, report);
  return true;
}
