import 'dart:math' as math;

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/config.dart';
import '../../data_collection/sync/sync_engine.dart' show SyncReport, retryDelay;
import '../api/learning_api.dart';
import '../db/learning_store.dart';
import '../models/learning_models.dart';

// Sends finished session registers to the CRM and keeps cached cohorts
// current. Same rules as the data collection sync:
//  • batches of up to 20; each item marked from the server's result —
//    accepted / duplicate / updated → sent, rejected → failed with the
//    reason (or retried later when the server says it's retryable);
//  • network, 5xx and 429 errors back off and end the run;
//  • 401 stops the run with the queue untouched;
//  • sent records are kept 30 days, then purged.
class LearningSync {
  LearningSync({
    required this.store,
    required this.api,
    required this.userId,
    required this.deviceId,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LearningStore store;
  final LearningApi api;
  final int userId;
  final String deviceId;
  final DateTime Function() _now;

  static bool _running = false;

  Future<SyncReport> run({bool force = false}) async {
    if (_running) return SyncReport.skipped('A sync is already running.');
    _running = true;
    var sent = 0;
    var failed = 0;
    String? error;
    var authExpired = false;

    try {
      final due = await store.dueForSync(userId, _now(), force: force);
      for (var i = 0; i < due.length; i += learningBatchSize) {
        final chunk = due.sublist(i, math.min(i + learningBatchSize, due.length));
        final uuids = chunk.map((r) => r.clientUuid).toList();
        await store.markSyncing(uuids);

        final List<Map<String, dynamic>> results;
        try {
          results = await api.submitBatch([for (final r in chunk) r.toPayload(deviceId: deviceId, appVersion: appVersion)]);
        } on AuthExpiredException {
          await store.revertToFinalized(uuids);
          authExpired = true;
          break;
        } on ApiException catch (e) {
          if (e.transient) {
            for (final r in chunk) {
              await _retryLater(r, e.message, e.retryAfter);
            }
            error = e.message;
            break;
          }
          for (final uuid in uuids) {
            await store.markFailed(uuid, e.message);
          }
          failed += uuids.length;
          continue;
        }

        final byUuid = {for (final r in results.map(LearningBatchResult.new)) r.clientUuid: r};
        for (final r in chunk) {
          final result = byUuid[r.clientUuid];
          if (result == null) {
            await _retryLater(r, 'The server did not confirm this session.', null);
          } else if (result.isStored) {
            await store.markSent(r.clientUuid, result.warnings, _now());
            sent++;
          } else if (result.retryable) {
            await _retryLater(r, 'The server could not process this session yet.', null);
          } else {
            await store.markFailed(r.clientUuid, describeRejection(result.reason));
            failed++;
          }
        }
      }

      if (!authExpired && error == null) {
        try {
          await refreshCohorts(changedOnly: true);
        } on AuthExpiredException {
          authExpired = true;
        } on ApiException catch (e) {
          error = e.message;
        }
      }

      await store.purgeSent(_now().subtract(const Duration(days: sentRetentionDays)));
      return SyncReport(sent: sent, failed: failed, pending: await store.pendingCount(userId), authExpired: authExpired, error: error);
    } finally {
      _running = false;
    }
  }

  // Downloads cohorts. changedOnly asks sync-status first and fetches only
  // the cohorts whose checksum moved (and drops removed ones).
  Future<int> refreshCohorts({bool changedOnly = false}) async {
    final known = await store.checksums(userId);
    List<Map<String, dynamic>> cohorts;
    if (changedOnly && known.isNotEmpty) {
      final status = await api.syncStatus(known);
      await store.removeCohorts(status.removed);
      if (status.changed.isEmpty) return 0;
      cohorts = await api.fetchCohorts(ids: status.changed);
    } else {
      cohorts = await api.fetchCohorts();
      final ids = cohorts.map((c) => c['id'] as int).toSet();
      await store.removeCohorts(known.keys.where((id) => !ids.contains(id)));
    }
    for (final c in cohorts) {
      await store.saveCohort(c, userId);
    }
    return cohorts.length;
  }

  Future<void> _retryLater(LocalSessionRecord r, String reason, Duration? retryAfter) {
    final attempts = r.attempts + 1;
    return store.scheduleRetry(r.clientUuid, attempts: attempts, nextAttemptAt: _now().add(retryDelay(attempts, retryAfter: retryAfter)), reason: reason);
  }
}
