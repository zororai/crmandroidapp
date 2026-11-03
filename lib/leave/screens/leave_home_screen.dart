import 'package:flutter/material.dart';

import '../../learning/widgets/learning_widgets.dart' show inkMuted, inkSecondary;
import '../../theme/brand_colors.dart';
import '../api/leave_api.dart';
import '../models/leave_models.dart';
import '../widgets/leave_widgets.dart';
import 'apply_leave_screen.dart';
import 'approvals_screen.dart';
import 'my_leave_screen.dart';
import 'team_calendar_screen.dart';

// Leave dashboard: a balance card per leave type, then the way to apply,
// your history, approvals and the team calendar. Everyone sees the same
// screen; the server decides what each list contains.
class LeaveHomeScreen extends StatefulWidget {
  const LeaveHomeScreen({super.key});

  @override
  State<LeaveHomeScreen> createState() => _LeaveHomeScreenState();
}

class _LeaveHomeScreenState extends State<LeaveHomeScreen> {
  List<LeaveBalance> _balances = [];
  int _year = DateTime.now().year;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await leaveCall(context, () async => (await createLeaveApi()).balances());
      if (!mounted || result == null) return;
      setState(() {
        _balances = result.balances;
        _year = result.year;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Widget screen) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => screen));
    if (changed == true || screen is ApplyLeaveScreen) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: leaveBackground,
      appBar: AppBar(title: const Text('Leave'), backgroundColor: leaveBackground, surfaceTintColor: Colors.transparent),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(ApplyLeaveScreen(balances: _balances)),
        icon: const Icon(Icons.add),
        label: const Text('Apply for leave'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: LeaveStateView(
          loading: _loading,
          error: _error,
          isEmpty: false,
          emptyIcon: Icons.beach_access_outlined,
          emptyText: '',
          onRetry: () {
            setState(() => _loading = true);
            _load();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Text('Your balances for $_year', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: inkSecondary)),
              const SizedBox(height: 8),
              if (_balances.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No leave types have been set up yet. Ask your administrator.', style: TextStyle(color: inkSecondary)),
                )
              else
                GridView.count(
                  crossAxisCount: MediaQuery.of(context).size.width > 600 ? 3 : 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.25,
                  children: [for (final b in _balances) _BalanceCard(balance: b)],
                ),
              const SizedBox(height: 24),
              _menu(Icons.history, 'My leave', 'Your requests and their status', () => _open(const MyLeaveScreen())),
              _menu(Icons.fact_check_outlined, 'Approvals', 'Requests waiting for your decision', () => _open(const ApprovalsScreen())),
              _menu(Icons.calendar_month_outlined, 'Team calendar', 'Who is off when', () => _open(const TeamCalendarScreen())),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menu(IconData icon, String title, String subtitle, VoidCallback onTap) => Card(
        elevation: 0,
        color: Colors.white,
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0x1A0B0B0B))),
        child: ListTile(
          leading: Icon(icon, color: brandPurple),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance});

  final LeaveBalance balance;

  @override
  Widget build(BuildContext context) {
    final b = balance;
    final paid = b.type.isPaid;
    final share = paid && b.entitled > 0 ? (b.remaining / b.entitled).clamp(0.0, 1.0) : null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0x1A0B0B0B))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(b.type.name, style: const TextStyle(fontSize: 13, color: inkSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Text(
          paid ? formatDays(b.remaining) : formatDays(b.used),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: brandInk),
        ),
        Text(paid ? 'of ${formatDays(b.entitled)} days left' : 'days taken (unpaid)', style: const TextStyle(fontSize: 11, color: inkMuted)),
        const Spacer(),
        if (share != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: share, minHeight: 6, color: brandPurple, backgroundColor: const Color(0x14000000)),
          ),
        if (b.pending > 0) ...[
          const SizedBox(height: 4),
          Text('${formatDays(b.pending)} pending', style: const TextStyle(fontSize: 11, color: inkSecondary)),
        ],
      ]),
    );
  }
}
