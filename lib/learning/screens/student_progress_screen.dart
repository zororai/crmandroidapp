import 'package:flutter/material.dart';

import '../../theme/brand_colors.dart';
import '../models/learning_models.dart';
import '../widgets/learning_widgets.dart';

// One student's progress in a cohort: the CRM's figures (attendance %,
// topics covered, assessed progress, completion, at-risk flags), their
// attendance session by session, and assessed-topic scores.
class StudentProgressScreen extends StatelessWidget {
  const StudentProgressScreen({super.key, required this.cohort, required this.student});

  final LearningCohort cohort;
  final LearningStudent student;

  @override
  Widget build(BuildContext context) {
    final s = student;
    final history = [
      for (final r in cohort.serverRecords)
        for (final a in ((r['attendance'] as List?) ?? const []).cast<Map<String, dynamic>>())
          if (a['enrollment_id'] == s.enrollmentId) (date: r['held_on'] as String, status: a['status'] as String, reason: a['reason'] as String?),
    ]..sort((a, b) => b.date.compareTo(a.date));
    final assessed = cohort.topics.where((t) => t.isAssessed).toList();
    final min = cohort.minAttendancePct;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(title: Text(s.name), backgroundColor: const Color(0xFFF7F6F3), surfaceTintColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text([if (s.studentRef != null) s.studentRef!, if (s.gender != null) s.gender!, if (s.age != null) '${s.age} yrs', s.status].join(' · '),
              style: const TextStyle(color: inkSecondary)),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.95,
            children: [
              MetricTile(label: 'Attendance', value: pct(s.attendancePct), caption: min == null ? null : 'target ${pct(min)}', icon: Icons.how_to_reg_outlined),
              MetricTile(label: 'Topics covered', value: pct(s.topicsCoveredPct), caption: 'while present', icon: Icons.menu_book_outlined),
              MetricTile(label: 'Assessed topics', value: pct(s.assessedProgressPct), caption: 'completed', icon: Icons.fact_check_outlined),
            ],
          ),
          const SizedBox(height: 12),
          if (s.eligibleForCompletion)
            const _Flag(icon: Icons.workspace_premium_outlined, color: statusGood, text: 'Meets the course completion rule — eligible to complete.'),
          for (final f in s.atRisk) _Flag(icon: Icons.warning_amber_rounded, color: statusWarning, text: riskLabel(f)),
          const SizedBox(height: 12),
          const Text('Assessed topics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brandInk)),
          const SizedBox(height: 8),
          if (assessed.isEmpty) const Text('This course has no assessed topics.', style: TextStyle(color: inkMuted)),
          for (final t in assessed) _assessment(t),
          const SizedBox(height: 16),
          const Text('Attendance history', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brandInk)),
          const Text('Recent sessions recorded in the CRM', style: TextStyle(fontSize: 12, color: inkMuted)),
          const SizedBox(height: 8),
          if (history.isEmpty) const Text('No sessions recorded yet.', style: TextStyle(color: inkMuted)),
          for (final h in history)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: hairline))),
              child: Row(children: [
                Expanded(child: Text(formatDate(h.date), style: const TextStyle(color: brandInk))),
                if (h.reason != null) Flexible(child: Text(h.reason!, style: const TextStyle(fontSize: 12, color: inkMuted), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                _statusPill(h.status),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _assessment(LearningTopic t) {
    final p = cohort.topicProgress.where((p) => p['enrollment_id'] == student.enrollmentId && p['topic_id'] == t.id).firstOrNull;
    final status = p?['status'] as String? ?? 'not_started';
    final score = (p?['score'] as num?)?.toDouble();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: hairline)),
      child: Row(children: [
        Expanded(child: Text(t.title, style: const TextStyle(color: brandInk))),
        if (score != null) Text('${pct(score)}  ', style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
        switch (status) {
          'completed' => const StatusPill(icon: Icons.check_circle_outline, label: 'Completed', color: statusGood),
          'in_progress' => const StatusPill(icon: Icons.timelapse, label: 'In progress', color: statusWarning),
          _ => const StatusPill(icon: Icons.radio_button_unchecked, label: 'Not started', color: inkMuted),
        },
      ]),
    );
  }

  Widget _statusPill(String status) => switch (status) {
        'present' => const StatusPill(icon: Icons.check, label: 'Present', color: statusGood),
        'late' => const StatusPill(icon: Icons.schedule, label: 'Late', color: statusWarning),
        'excused' => const StatusPill(icon: Icons.info_outline, label: 'Excused', color: inkMuted),
        _ => const StatusPill(icon: Icons.close, label: 'Absent', color: statusCritical),
      };
}

class _Flag extends StatelessWidget {
  const _Flag({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [Icon(icon, color: color, size: 20), const SizedBox(width: 10), Expanded(child: Text(text))]),
      );
}
