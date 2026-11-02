import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/brand_colors.dart';

const inkSecondary = Color(0xFF52514E);
const inkMuted = Color(0xFF898781);
const hairline = Color(0x1A0B0B0B);

// State shown as icon + label; colour only reinforces it.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: brandInk)),
        ]),
      );
}

StatusPill scheduleStatusPill(String? status) => switch (status) {
      'ahead' => const StatusPill(icon: Icons.trending_up, label: 'Ahead of plan', color: statusGood),
      'behind' => const StatusPill(icon: Icons.trending_down, label: 'Behind plan', color: statusCritical),
      _ => const StatusPill(icon: Icons.check_circle_outline, label: 'On track', color: statusGood),
    };

// label · value in ink; optional caption under the value.
class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.label, required this.value, this.caption, this.icon});

  final String label;
  final String value;
  final String? caption;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: hairline)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 16, color: brandPurple), const SizedBox(width: 6)],
              Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: inkSecondary), maxLines: 2, overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: brandInk)),
            if (caption != null) Text(caption!, style: const TextStyle(fontSize: 11, color: inkMuted)),
          ],
        ),
      );
}

String pct(double? v) => v == null ? '—' : '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}%';

String formatDate(String isoDate) {
  final d = DateTime.tryParse(isoDate);
  return d == null ? isoDate : DateFormat('EEE d MMM').format(d);
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}

String riskLabel(Map<String, dynamic> flag) => switch (flag['code']) {
      'consecutive_absences' => 'Absent ${flag['value']} sessions in a row',
      'low_attendance' => 'Attendance below target (${flag['value']}%)',
      'behind_schedule' => 'Behind schedule by ${flag['value']} sessions',
      'unrecorded_sessions' => '${flag['value']} past session(s) not recorded',
      _ => '${flag['code']}',
    };
