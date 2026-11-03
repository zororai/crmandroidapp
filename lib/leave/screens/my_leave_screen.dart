import 'package:flutter/material.dart';

import '../api/leave_api.dart';
import '../models/leave_models.dart';
import '../widgets/leave_widgets.dart';
import 'leave_detail_screen.dart';

// Your own leave requests, newest first, filterable by status.
class MyLeaveScreen extends StatefulWidget {
  const MyLeaveScreen({super.key});

  @override
  State<MyLeaveScreen> createState() => _MyLeaveScreenState();
}

class _MyLeaveScreenState extends State<MyLeaveScreen> {
  List<LeaveRequest> _requests = [];
  LeaveStatus? _filter;
  bool _loading = true;
  Object? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final requests = await leaveCall(context, () async => (await createLeaveApi()).myRequests(status: _filter));
      if (!mounted || requests == null) return;
      setState(() {
        _requests = requests;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setFilter(LeaveStatus? status) {
    setState(() {
      _filter = status;
      _loading = true;
    });
    _load();
  }

  Future<void> _open(LeaveRequest r) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => LeaveDetailScreen(requestId: r.id)));
    if (changed == true) {
      _changed = true;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: leaveBackground,
        appBar: AppBar(title: const Text('My leave'), backgroundColor: leaveBackground, surfaceTintColor: Colors.transparent),
        body: Column(children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(children: [
              _chip('All', null),
              for (final s in LeaveStatus.values) _chip(s.label, s),
            ]),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: LeaveStateView(
                loading: _loading,
                error: _error,
                isEmpty: _requests.isEmpty,
                emptyIcon: Icons.event_available_outlined,
                emptyText: _filter == null
                    ? 'You have not applied for any leave yet.'
                    : 'No ${_filter!.label.toLowerCase()} requests.',
                onRetry: () => _setFilter(_filter),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  itemCount: _requests.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => LeaveRequestCard(request: _requests[i], onTap: () => _open(_requests[i])),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _chip(String label, LeaveStatus? status) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text(label),
          selected: _filter == status,
          showCheckmark: false,
          onSelected: (_) => _setFilter(status),
        ),
      );
}
