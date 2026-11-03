import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data_collection/api/data_collection_api.dart' show ApiException;
import '../../learning/widgets/learning_widgets.dart' show inkMuted, inkSecondary;
import '../../theme/brand_colors.dart';
import '../api/leave_api.dart';
import '../models/leave_models.dart';
import '../widgets/decision_dialog.dart';
import '../widgets/leave_widgets.dart';

// One request: its details and what has happened to it so far. Cancel shows
// for the owner of a pending request; approve/reject for someone who may
// decide it. Both come from the server's `can` flags, and the server
// re-checks when the button is pressed. Pops true if anything changed.
class LeaveDetailScreen extends StatefulWidget {
  const LeaveDetailScreen({super.key, required this.requestId});

  final int requestId;

  @override
  State<LeaveDetailScreen> createState() => _LeaveDetailScreenState();
}

class _LeaveDetailScreenState extends State<LeaveDetailScreen> {
  LeaveRequest? _request;
  bool _loading = true;
  Object? _error;
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await leaveCall(context, () async => (await createLeaveApi()).request(widget.requestId));
      if (!mounted || r == null) return;
      setState(() {
        _request = r;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _act(Future<LeaveRequest> Function(LeaveApi api) action, String done) async {
    setState(() => _busy = true);
    try {
      final updated = await leaveCall(context, () async => action(await createLeaveApi()));
      if (updated == null || !mounted) return;
      setState(() {
        _request = updated;
        _changed = true;
      });
      showLeaveSnack(context, done);
    } on ApiException catch (e) {
      if (mounted) showLeaveSnack(context, e.message);
      _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: const Text('Your manager will no longer see it. You can apply again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cancel request')),
        ],
      ),
    );
    if (ok == true) await _act((api) => api.cancel(widget.requestId), 'Request cancelled.');
  }

  Future<void> _decide({required bool approve}) async {
    final comment = await showDecisionDialog(context, _request!, approve: approve);
    if (comment == null) return;
    await _act(
      (api) => approve ? api.approve(widget.requestId, comment: comment) : api.reject(widget.requestId, comment),
      approve ? 'Leave approved.' : 'Leave rejected.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _request;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: leaveBackground,
        appBar: AppBar(title: const Text('Leave request'), backgroundColor: leaveBackground, surfaceTintColor: Colors.transparent),
        body: RefreshIndicator(
          onRefresh: _load,
          child: LeaveStateView(
            loading: _loading,
            error: _error,
            isEmpty: r == null,
            emptyIcon: Icons.search_off,
            emptyText: 'This request could not be found.',
            onRetry: () {
              setState(() => _loading = true);
              _load();
            },
            child: r == null ? const SizedBox.shrink() : _details(r),
          ),
        ),
      ),
    );
  }

  Widget _details(LeaveRequest r) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(child: Text('${r.type.name} leave', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: brandInk))),
            leaveStatusPill(r.status),
          ]),
          if (r.user != null) Text(r.user!.name, style: const TextStyle(color: inkSecondary)),
          const SizedBox(height: 16),
          _row(Icons.date_range, formatDateRange(r.start, r.end)),
          _row(Icons.work_history_outlined, daysLabel(r.days)),
          if (r.reason != null && r.reason!.isNotEmpty) _row(Icons.notes, r.reason!),
          if (r.hasAttachment) _row(Icons.attach_file, 'Supporting document attached'),
          const SizedBox(height: 24),
          const Text('Timeline', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: inkSecondary)),
          const SizedBox(height: 8),
          ..._timeline(r),
          const SizedBox(height: 24),
          if (r.canDecide)
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _decide(approve: false),
                  icon: const Icon(Icons.close),
                  label: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _decide(approve: true),
                  icon: const Icon(Icons.check),
                  label: const Text('Approve'),
                ),
              ),
            ]),
          if (r.canCancel)
            OutlinedButton.icon(
              onPressed: _busy ? null : _cancel,
              icon: const Icon(Icons.block),
              label: const Text('Cancel this request'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
        ],
      );

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: brandPurple),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      );

  List<Widget> _timeline(LeaveRequest r) {
    final when = DateFormat('d MMM yyyy, HH:mm');
    final steps = <_Step>[
      _Step(Icons.send_outlined, 'Applied', r.createdAt == null ? null : when.format(r.createdAt!), statusGood),
      if (r.status == LeaveStatus.pending)
        const _Step(Icons.hourglass_top, 'Waiting for a decision', 'Your line manager has been told.', statusWarning, current: true),
      if (r.decidedAt != null)
        _Step(
          r.status == LeaveStatus.rejected ? Icons.cancel_outlined : Icons.check_circle_outline,
          '${r.status == LeaveStatus.rejected ? 'Rejected' : 'Approved'}${r.approver != null ? ' by ${r.approver!.name}' : ''}',
          [when.format(r.decidedAt!), if (r.approverComment != null && r.approverComment!.isNotEmpty) '“${r.approverComment}”'].join('\n'),
          r.status == LeaveStatus.rejected ? statusCritical : statusGood,
        ),
      if (r.cancelledAt != null) _Step(Icons.block, 'Cancelled', when.format(r.cancelledAt!), inkMuted),
      if (r.correctedAt != null)
        _Step(Icons.edit_note, 'Decision corrected — now ${r.status.label.toLowerCase()}',
            [when.format(r.correctedAt!), if (r.correctionReason != null) r.correctionReason!].join('\n'), brandPurple),
    ];
    return [for (var i = 0; i < steps.length; i++) _TimelineTile(step: steps[i], last: i == steps.length - 1)];
  }
}

class _Step {
  const _Step(this.icon, this.title, this.subtitle, this.color, {this.current = false});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;
  final bool current;
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.step, required this.last});

  final _Step step;
  final bool last;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Column(children: [
            Icon(step.icon, size: 22, color: step.color),
            if (!last) Expanded(child: Container(width: 2, color: const Color(0x1A0B0B0B))),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(step.title, style: TextStyle(fontWeight: step.current ? FontWeight.w700 : FontWeight.w600, color: brandInk)),
                if (step.subtitle != null) Text(step.subtitle!, style: const TextStyle(fontSize: 13, color: inkSecondary)),
              ]),
            ),
          ),
        ]),
      );
}
