import 'package:flutter/material.dart';

import '../../data_collection/api/data_collection_api.dart' show ApiException;
import '../api/leave_api.dart';
import '../models/leave_models.dart';
import '../widgets/decision_dialog.dart';
import '../widgets/leave_widgets.dart';
import 'leave_detail_screen.dart';

// Requests waiting for this person's decision. Opens for everyone; the
// server sends an empty list to anyone who doesn't approve leave.
class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends State<ApprovalsScreen> {
  List<LeaveRequest> _pending = [];
  bool _loading = true;
  Object? _error;
  final _busy = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pending = await leaveCall(context, () async => (await createLeaveApi()).pending());
      if (!mounted || pending == null) return;
      setState(() {
        _pending = pending;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(LeaveRequest r, {required bool approve}) async {
    final comment = await showDecisionDialog(context, r, approve: approve);
    if (comment == null || !mounted) return;

    setState(() => _busy.add(r.id));
    try {
      final done = await leaveCall(context, () async {
        final api = await createLeaveApi();
        return approve ? api.approve(r.id, comment: comment) : api.reject(r.id, comment);
      });
      if (done == null || !mounted) return;
      setState(() => _pending.removeWhere((p) => p.id == r.id));
      showLeaveSnack(context, '${r.user?.name ?? 'Leave'}: ${approve ? 'approved' : 'rejected'}.');
    } on ApiException catch (e) {
      if (mounted) showLeaveSnack(context, e.message);
      _load();
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  Future<void> _open(LeaveRequest r) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => LeaveDetailScreen(requestId: r.id)));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: leaveBackground,
      appBar: AppBar(title: const Text('Approvals'), backgroundColor: leaveBackground, surfaceTintColor: Colors.transparent),
      body: RefreshIndicator(
        onRefresh: _load,
        child: LeaveStateView(
          loading: _loading,
          error: _error,
          isEmpty: _pending.isEmpty,
          emptyIcon: Icons.fact_check_outlined,
          emptyText: 'Nothing to approve.\nLeave requests from people who report to you will show here, '
              'if you have been given leave approval in the CRM.',
          onRetry: () {
            setState(() => _loading = true);
            _load();
          },
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: _pending.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final r = _pending[i];
              final busy = _busy.contains(r.id);
              return LeaveRequestCard(
                request: r,
                showPerson: true,
                onTap: () => _open(r),
                trailing: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy || !r.canDecide ? null : () => _decide(r, approve: false),
                      child: const Text('Reject'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy || !r.canDecide ? null : () => _decide(r, approve: true),
                      child: busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Approve'),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}
