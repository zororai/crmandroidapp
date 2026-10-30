import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'background_sync.dart';
import 'sync_engine.dart';
import 'sync_runner.dart';

// Foreground sync triggers: app start, connectivity coming back, after a
// submission is finalized, and the "Sync now" buttons. Screens listen to
// [running] / [lastReport] to show progress and results.
class SyncCoordinator {
  SyncCoordinator._();

  static final instance = SyncCoordinator._();

  final running = ValueNotifier<bool>(false);
  final lastReport = ValueNotifier<SyncReport?>(null);

  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  bool _wasOffline = false;

  void start() {
    _connectivity ??= Connectivity().onConnectivityChanged.listen((results) {
      final offline = results.every((r) => r == ConnectivityResult.none);
      if (_wasOffline && !offline) sync();
      _wasOffline = offline;
    });
    sync();
  }

  Future<SyncReport> sync({bool force = false}) async {
    if (running.value) return lastReport.value ?? SyncReport.skipped('A sync is already running.');
    running.value = true;
    try {
      final report = await SyncRunner.run(force: force);
      if (!report.skipped || lastReport.value == null) lastReport.value = report;
      return report;
    } catch (e) {
      final report = SyncReport(error: '$e');
      lastReport.value = report;
      return report;
    } finally {
      running.value = false;
    }
  }

  Future<void> onFinalized() async {
    await BackgroundSync.scheduleOneOff();
    unawaited(sync());
  }
}
