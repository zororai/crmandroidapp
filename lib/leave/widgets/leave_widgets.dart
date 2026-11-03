import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/screens/sync_ui.dart' show promptReauth;
import '../../learning/widgets/learning_widgets.dart' show StatusPill, inkMuted, inkSecondary;
import '../../theme/brand_colors.dart';
import '../models/leave_models.dart';

const leaveBackground = Color(0xFFF7F6F3);

StatusPill leaveStatusPill(LeaveStatus s) => switch (s) {
      LeaveStatus.pending => StatusPill(icon: Icons.hourglass_top, label: s.label, color: statusWarning),
      LeaveStatus.approved => StatusPill(icon: Icons.check_circle_outline, label: s.label, color: statusGood),
      LeaveStatus.rejected => StatusPill(icon: Icons.cancel_outlined, label: s.label, color: statusCritical),
      LeaveStatus.cancelled => StatusPill(icon: Icons.block, label: s.label, color: inkMuted),
    };

String formatDateRange(DateTime start, DateTime end) {
  final sameYear = start.year == end.year;
  if (start == end) return DateFormat('EEE d MMM yyyy').format(start);
  return '${DateFormat(sameYear ? 'EEE d MMM' : 'EEE d MMM yyyy').format(start)} – ${DateFormat('EEE d MMM yyyy').format(end)}';
}

String daysLabel(num days) => '${formatDays(days)} working day${days == 1 ? '' : 's'}';

// What went wrong, in words for the person holding the phone.
String leaveErrorText(Object error) {
  if (error is AuthExpiredException) return 'Your login has expired. Log in again to see your leave.';
  if (error is ApiException) return error.message;
  return 'Something went wrong. Pull down to try again.';
}

bool isForbidden(Object? error) => error is ApiException && error.statusCode == 403;

// Runs a server call from a screen: a 401 offers to log in again, anything
// else is rethrown for the screen to show. Returns null if it gave up.
Future<T?> leaveCall<T>(BuildContext context, Future<T> Function() call) async {
  try {
    return await call();
  } on AuthExpiredException {
    if (context.mounted) await promptReauth(context);
    return null;
  }
}

void showLeaveSnack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

// The body every leave screen shares: spinner on first load, then the
// content, an empty message, a "not available to you" message for a 403, or
// the error with a retry. Always scrollable, so pull-to-refresh works in
// every state.
class LeaveStateView extends StatelessWidget {
  const LeaveStateView({
    super.key,
    required this.loading,
    required this.error,
    required this.isEmpty,
    required this.emptyIcon,
    required this.emptyText,
    required this.onRetry,
    required this.child,
    this.forbiddenIcon = Icons.lock_outline,
  });

  final bool loading;
  final Object? error;
  final bool isEmpty;
  final IconData emptyIcon;
  final String emptyText;
  final IconData forbiddenIcon;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      final forbidden = isForbidden(error);
      return _Message(
        icon: forbidden ? forbiddenIcon : Icons.cloud_off_outlined,
        text: leaveErrorText(error!),
        action: forbidden ? null : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
      );
    }
    if (isEmpty) return _Message(icon: emptyIcon, text: emptyText);
    return child;
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
            child: Column(children: [
              Icon(icon, size: 48, color: inkMuted),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: inkSecondary)),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ]),
          ),
        ],
      );
}

// One leave request as a tappable card (history, approvals).
class LeaveRequestCard extends StatelessWidget {
  const LeaveRequestCard({super.key, required this.request, required this.onTap, this.showPerson = false, this.trailing});

  final LeaveRequest request;
  final VoidCallback onTap;
  final bool showPerson;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0x1A0B0B0B))),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    showPerson ? (request.user?.name ?? '') : '${request.type.name} leave',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brandInk),
                  ),
                ),
                leaveStatusPill(request.status),
              ]),
              const SizedBox(height: 4),
              if (showPerson) Text('${request.type.name} leave', style: const TextStyle(color: inkSecondary)),
              Text(formatDateRange(request.start, request.end), style: const TextStyle(color: inkSecondary)),
              Text(daysLabel(request.days), style: const TextStyle(fontSize: 12, color: inkMuted)),
              if (request.reason != null && request.reason!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(request.reason!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: inkSecondary)),
              ],
              if (trailing != null) ...[const SizedBox(height: 12), trailing!],
            ]),
          ),
        ),
      );
}
