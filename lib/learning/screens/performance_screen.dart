import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/screens/sync_ui.dart';
import '../../data_collection/sync/sync_runner.dart';
import '../../theme/brand_colors.dart';
import '../widgets/learning_widgets.dart';

const _cacheKey = 'learning_performance';

// The facilitator's own delivery figures from the CRM (GET
// /learning/me/performance). The last result is kept so it still shows
// offline, with the time it was fetched.
class PerformanceScreen extends StatefulWidget {
  const PerformanceScreen({super.key});

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen> {
  Map<String, dynamic>? _figures;
  DateTime? _asOf;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCached().then((_) => _refresh());
  }

  Future<void> _loadCached() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw == null) return;
      final cached = jsonDecode(raw) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _figures = (cached['figures'] as Map).cast<String, dynamic>();
          _asOf = DateTime.tryParse(cached['as_of'] as String? ?? '');
        });
      }
    } catch (_) {}
  }

  Future<void> _refresh() async {
    try {
      final sync = await SyncRunner.learningSync();
      if (sync == null) throw AuthExpiredException();
      final figures = await sync.api.performance();
      final now = DateTime.now();
      await (await SharedPreferences.getInstance()).setString(_cacheKey, jsonEncode({'figures': figures, 'as_of': now.toIso8601String()}));
      if (mounted) {
        setState(() {
          _figures = figures;
          _asOf = now;
          _error = null;
        });
      }
    } on AuthExpiredException {
      if (mounted) await promptReauth(context);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.transient ? 'Offline — showing the last figures downloaded.' : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _figures;
    num? n(String k) => f?[k] as num?;
    String count(String k) => n(k) == null ? '—' : '${n(k)}';

    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(title: const Text('My Performance'), backgroundColor: const Color(0xFFF7F6F3), surfaceTintColor: Colors.transparent),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: inkSecondary))),
            if (f == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
            if (f != null) ...[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: hairline)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Sessions held on time', style: TextStyle(color: inkSecondary)),
                    Text(pct(n('on_time_pct')?.toDouble()),
                        style: const TextStyle(fontSize: 48, height: 1.1, fontWeight: FontWeight.w600, color: brandInk)),
                    Text('${count('sessions_held_on_time')} of ${count('sessions_due')} sessions due, across ${count('cohorts')} cohort(s)',
                        style: const TextStyle(color: inkSecondary)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.6,
                children: [
                  MetricTile(label: 'Held late (other day)', value: count('sessions_held_late'), icon: Icons.event_repeat),
                  MetricTile(label: 'Missed (not recorded)', value: count('sessions_missed'), icon: Icons.event_busy_outlined),
                  MetricTile(label: 'Late syncs', value: count('late_syncs'), caption: 'sent long after the session', icon: Icons.cloud_sync_outlined),
                  MetricTile(
                    label: 'Average session',
                    value: n('avg_duration_minutes') == null ? '—' : formatDuration(Duration(minutes: n('avg_duration_minutes')!.toInt())),
                    icon: Icons.timer_outlined,
                  ),
                  MetricTile(label: 'Student attendance', value: pct(n('attendance_rate_pct')?.toDouble()), caption: 'present or late', icon: Icons.groups_outlined),
                  MetricTile(label: 'Sessions recorded', value: count('sessions_recorded'), icon: Icons.fact_check_outlined),
                ],
              ),
              if (_asOf != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('As of ${DateFormat('d MMM yyyy, HH:mm').format(_asOf!)}', style: const TextStyle(fontSize: 12, color: inkMuted)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
