import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'sync_runner.dart';

const _taskName = 'dataCollectionSync';
const _periodicId = 'dc-periodic-sync';
const _oneOffId = 'dc-one-off-sync';

// Runs in a separate isolate started by WorkManager, with none of the app's
// in-memory state: SyncRunner opens the database, reads the session/token
// and server address from storage itself.
@pragma('vm:entry-point')
void dataCollectionCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await SyncRunner.run();
    } catch (_) {
      // Retries are scheduled by the sync queue itself (nextAttemptAt), so
      // the task always reports success rather than stacking WorkManager's
      // own retries on top.
    }
    return true;
  });
}

// Android only. In Chrome (and on desktop) sync runs only while the app is
// open: on start, when connectivity returns, after finalizing, and on demand.
class BackgroundSync {
  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void> initialize() async {
    if (!supported) return;
    await Workmanager().initialize(dataCollectionCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _periodicId,
      _taskName,
      frequency: const Duration(minutes: 15), // Android's minimum
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  // After finalizing offline: Android runs this as soon as a network is
  // available, even if the app has been closed by then.
  static Future<void> scheduleOneOff() async {
    if (!supported) return;
    await Workmanager().registerOneOffTask(
      _oneOffId,
      _taskName,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }
}
