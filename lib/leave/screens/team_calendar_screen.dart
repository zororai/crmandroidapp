import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../learning/widgets/learning_widgets.dart' show inkMuted, inkSecondary;
import '../../theme/brand_colors.dart';
import '../api/leave_api.dart';
import '../models/leave_models.dart';
import '../widgets/leave_widgets.dart';
import 'leave_detail_screen.dart';

// Who is off when, a month at a time: each day shows how many people are on
// approved or pending leave; tap a day to see who. For approvers (their
// team) and leave admins (everyone); anyone else gets the server's 403
// message in place of the calendar.
class TeamCalendarScreen extends StatefulWidget {
  const TeamCalendarScreen({super.key});

  @override
  State<TeamCalendarScreen> createState() => _TeamCalendarScreenState();
}

class _TeamCalendarScreenState extends State<TeamCalendarScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime _selected = _today;
  TeamCalendar? _calendar;
  bool _loading = true;
  Object? _error;

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final from = _month;
    final to = DateTime(_month.year, _month.month + 1, 0);
    try {
      final cal = await leaveCall(context, () async => (await createLeaveApi()).calendar(from, to));
      if (!mounted || cal == null || from != _month) return;
      setState(() {
        _calendar = cal;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = _month.year == _today.year && _month.month == _today.month ? _today : _month;
      _loading = true;
    });
    _load();
  }

  List<LeaveRequest> _offOn(DateTime day) => _calendar?.requests.where((r) => r.covers(day)).toList() ?? const [];

  PublicHoliday? _holidayOn(DateTime day) =>
      _calendar?.holidays.where((h) => h.date.year == day.year && h.date.month == day.month && h.date.day == day.day).firstOrNull;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: leaveBackground,
      appBar: AppBar(title: const Text('Team calendar'), backgroundColor: leaveBackground, surfaceTintColor: Colors.transparent),
      body: RefreshIndicator(
        onRefresh: _load,
        child: LeaveStateView(
          loading: _loading,
          error: _error,
          isEmpty: false,
          emptyIcon: Icons.calendar_month_outlined,
          emptyText: '',
          forbiddenIcon: Icons.calendar_month_outlined,
          onRetry: () {
            setState(() => _loading = true);
            _load();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
            children: [
              Row(children: [
                IconButton(tooltip: 'Previous month', onPressed: () => _shiftMonth(-1), icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: Text(DateFormat('MMMM yyyy').format(_month),
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                IconButton(tooltip: 'Next month', onPressed: () => _shiftMonth(1), icon: const Icon(Icons.chevron_right)),
              ]),
              _grid(),
              const SizedBox(height: 16),
              _dayDetail(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grid() {
    final first = _month;
    final daysInMonth = DateTime(first.year, first.month + 1, 0).day;
    final leading = first.weekday - 1; // Monday first
    final cells = leading + daysInMonth;

    return Column(children: [
      Row(children: [
        for (final d in ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
          Expanded(child: Center(child: Text(d, style: const TextStyle(fontSize: 12, color: inkMuted)))),
      ]),
      const SizedBox(height: 4),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisSpacing: 4, crossAxisSpacing: 4),
        itemCount: cells + (7 - cells % 7) % 7,
        itemBuilder: (context, i) {
          final dayNum = i - leading + 1;
          if (dayNum < 1 || dayNum > daysInMonth) return const SizedBox.shrink();
          final day = DateTime(first.year, first.month, dayNum);
          final off = _offOn(day).length;
          final holiday = _holidayOn(day) != null;
          final weekend = day.weekday >= DateTime.saturday;
          final selected = day == _selected;

          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _selected = day),
            child: Container(
              decoration: BoxDecoration(
                color: selected ? brandPurple.withValues(alpha: 0.12) : (weekend || holiday ? const Color(0x08000000) : Colors.white),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: selected ? brandPurple : const Color(0x1A0B0B0B), width: selected ? 1.5 : 1),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('$dayNum', style: TextStyle(fontWeight: day == _today ? FontWeight.w800 : FontWeight.w500, color: weekend ? inkMuted : brandInk)),
                if (holiday)
                  const Icon(Icons.celebration_outlined, size: 12, color: brandOrange)
                else if (off > 0)
                  Text('$off off', style: const TextStyle(fontSize: 10, color: brandPurple, fontWeight: FontWeight.w600)),
              ]),
            ),
          );
        },
      ),
    ]);
  }

  Widget _dayDetail() {
    final off = _offOn(_selected);
    final holiday = _holidayOn(_selected);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(DateFormat('EEEE d MMMM').format(_selected), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: inkSecondary)),
      const SizedBox(height: 8),
      if (holiday != null)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.celebration_outlined, color: brandOrange),
          title: Text(holiday.name),
          subtitle: const Text('Public holiday'),
        ),
      if (off.isEmpty && holiday == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Nobody in your team is off on this day.', style: TextStyle(color: inkSecondary)),
        ),
      for (final r in off)
        Card(
          elevation: 0,
          color: Colors.white,
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0x1A0B0B0B))),
          child: ListTile(
            title: Text(r.user?.name ?? ''),
            subtitle: Text('${r.type.name} · ${formatDateRange(r.start, r.end)}'),
            trailing: leaveStatusPill(r.status),
            onTap: () async {
              final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => LeaveDetailScreen(requestId: r.id)));
              if (changed == true) _load();
            },
          ),
        ),
    ]);
  }
}
