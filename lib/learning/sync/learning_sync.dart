import 'dart:math' as math;

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/config.dart';
import '../../data_collection/sync/sync_engine.dart' show SyncReport, retryDelay;
import '../api/learning_api.dart';
import '../db/learning_store.dart';
import '../models/learning_models.dart';

// Uploads what the teacher set up and recorded, then refreshes classes.
//  1. Setup (courses + topics, classes, new students, enrollments) — before
//     sessions, which may refer to them.
//  2. Sessions, in batches of up to 20; a class still waiting for its setup
//     holds its sessions back. accepted / duplicate / updated → sent,
//     rejected → failed with the reason (or retried when retryable).
//  3. Classes whose checksum changed are downloaded again.
// Network, 5xx and 429 errors back off and end the run; a 401 stops it with
// everything still queued.
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
      try {
        failed += await uploadSetup();
      } on AuthExpiredException {
        authExpired = true;
      } on ApiException catch (e) {
        error = e.message;
      }

      if (!authExpired && error == null) {
        final waiting = await store.cohortsAwaitingSetup(userId);
        final due = (await store.dueForSync(userId, _now(), force: force)).where((r) => !waiting.contains(r.cohortUuid)).toList();
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

  // Sends every pending setup item in one request. Returns how many the
  // CRM rejected. Throws on network/auth errors (items stay pending).
  Future<int> uploadSetup() async {
    final items = await store.setupItems(ownerUserId: userId, onlyPending: true);
    if (items.isEmpty) return 0;

    // Keys starting with _ are for this device only (e.g. how to show a
    // student before the CRM confirms them).
    Map<String, dynamic> clean(Map<String, dynamic> j) => {for (final e in j.entries) if (!e.key.startsWith('_')) e.key: e.value};
    final payload = <String, List<Map<String, dynamic>>>{
      for (final kind in ['course', 'cohort', 'student', 'enrollment'])
        '${kind == 'cohort' ? 'cohorts' : '${kind}s'}': [for (final i in items.where((i) => i.kind == kind)) clean(i.json)],
    }..removeWhere((_, v) => v.isEmpty);

    final results = (await api.setup(payload)).map(LearningBatchResult.new).toList();
    var rejected = 0;
    for (final item in items) {
      final mine = results.where((r) => r.kind == item.kind && r.clientUuid == item.clientUuid).firstOrNull;
      // A course is only done when its topics are too.
      final topicProblem = item.kind == 'course'
          ? results.where((r) => r.kind == 'topic' && !r.isStored && (item.json['topics'] as List).any((t) => (t as Map)['client_uuid'] == r.clientUuid)).firstOrNull
          : null;

      if (mine == null || (mine.retryable && !mine.isStored)) {
        continue; // stays pending; tried again next sync
      }
      if (mine.isStored && topicProblem == null) {
        await store.markSetup(item.clientUuid, SetupStatus.sent);
        final serverUuid = mine.serverClientUuid;
        if (item.kind == 'enrollment' && serverUuid != null && serverUuid != item.clientUuid) {
          // Already in this class in the CRM: adopt the CRM's enrollment.
          await store.replaceEnrollmentUuid(item.cohortUuid, item.clientUuid, serverUuid);
        }
      } else {
        await store.markSetup(item.clientUuid, SetupStatus.failed, reason: describeRejection((topicProblem ?? mine).reason));
        rejected++;
      }
    }
    return rejected;
  }

  // Downloads classes. changedOnly asks sync-status first and fetches only
  // classes whose checksum moved (or that are new to the device). Classes
  // created here and not yet confirmed are never dropped.
  Future<int> refreshCohorts({bool changedOnly = false}) async {
    final known = await store.checksums(userId);
    final keep = await store.cohortsAwaitingSetup(userId);
    List<Map<String, dynamic>> cohorts;
    if (changedOnly) {
      final status = await api.syncStatus(known);
      final removedUuids = [
        for (final c in await store.cohorts(userId))
          if (status.removed.contains(c.json['id']) && !keep.contains(c.uuid)) c.uuid,
      ];
      await store.removeCohorts(removedUuids);
      if (status.changed.isEmpty) return 0;
      cohorts = await api.fetchCohorts(ids: status.changed);
    } else {
      cohorts = await api.fetchCohorts();
      final serverUuids = cohorts.map((c) => c['client_uuid']).toSet();
      await store.removeCohorts([
        for (final c in await store.cohorts(userId))
          if (!serverUuids.contains(c.uuid) && !keep.contains(c.uuid) && !c.isLocal) c.uuid,
      ]);
    }
    for (final c in cohorts) {
      await store.saveDownloadedCohort(c, userId);
    }
    return cohorts.length;
  }

  Future<void> _retryLater(LocalSessionRecord r, String reason, Duration? retryAfter) {
    final attempts = r.attempts + 1;
    return store.scheduleRetry(r.clientUuid, attempts: attempts, nextAttemptAt: _now().add(retryDelay(attempts, retryAfter: retryAfter)), reason: reason);
  }
}
