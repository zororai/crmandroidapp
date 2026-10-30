import 'dart:math' as math;

import '../api/data_collection_api.dart';
import '../config.dart';
import '../db/data_collection_store.dart';
import '../media/media_files.dart';
import '../models/api_models.dart';
import '../models/submission.dart';

// Exponential backoff for transient failures: 30s, 1m, 2m, 4m … capped at
// 1h. A server Retry-After (429) wins if it asks for longer.
Duration retryDelay(int attempts, {Duration? retryAfter}) {
  final seconds = math.min(30 * math.pow(2, math.max(0, attempts - 1)).toInt(), 3600);
  final backoff = Duration(seconds: seconds);
  return retryAfter != null && retryAfter > backoff ? retryAfter : backoff;
}

class SyncReport {
  SyncReport({this.sent = 0, this.failed = 0, this.pending = 0, this.authExpired = false, this.error, this.skipped = false, DateTime? finishedAt})
      : finishedAt = finishedAt ?? DateTime.now();

  SyncReport.skipped(String reason) : this(skipped: true, error: reason);

  final int sent; // fully delivered this run (data + photos)
  final int failed; // rejected by the server this run
  final int pending; // still queued after the run
  final bool authExpired;
  final String? error; // last transient/connection problem, if any
  final bool skipped; // nothing attempted (not logged in, already running…)
  final DateTime finishedAt;

  bool get ok => !authExpired && error == null;
}

// Pushes finalized submissions to the CRM for one user:
//  1. data, in batches of submissionBatchSize; each item is marked from the
//     server's per-item result (accepted/duplicate → stored, rejected →
//     failed with the reason);
//  2. photos, only for submissions whose data the server has stored;
//  3. a submission becomes 'sent' once data and every photo are in.
// Transient errors (network, 5xx, 429) reschedule with backoff and end the
// run; nothing is deleted locally until the server confirms it. A 401 stops
// the run with the queue untouched so the user can log in again.
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.api,
    required this.userId,
    required this.deviceId,
    this.mediaFiles = const MediaFiles(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DataCollectionStore store;
  final DataCollectionApi api;
  final int userId;
  final String deviceId;
  final MediaFiles mediaFiles;
  final DateTime Function() _now;

  // One run at a time per isolate. The background isolate can overlap a
  // foreground run; that's safe because the server is idempotent on
  // client_uuid, at worst a duplicate result.
  static bool _running = false;

  Future<SyncReport> run({bool force = false}) async {
    if (_running) return SyncReport.skipped('A sync is already running.');
    _running = true;
    final startedAt = _now();
    var sent = 0;
    var failed = 0;
    String? error;
    var authExpired = false;

    try {
      final due = await store.dueForSync(userId, _now(), force: force);

      // ── 1. Data ──
      final needData = due.where((s) => !s.dataAccepted).toList();
      for (var i = 0; i < needData.length; i += submissionBatchSize) {
        final chunk = needData.sublist(i, math.min(i + submissionBatchSize, needData.length));
        final outcome = await _sendData(chunk);
        failed += outcome.failed;
        if (outcome.authExpired) {
          authExpired = true;
          break;
        }
        if (outcome.transientError != null) {
          error = outcome.transientError;
          break;
        }
      }

      // ── 2. Photos, then 3. mark sent ──
      if (!authExpired && error == null) {
        final dataStored = await store.dueForSync(userId, _now(), force: force);
        for (final s in dataStored.where((s) => s.dataAccepted)) {
          final outcome = await _sendMedia(s);
          if (outcome == _MediaOutcome.sent) sent++;
          if (outcome == _MediaOutcome.failed) failed++;
          if (outcome == _MediaOutcome.authExpired) {
            authExpired = true;
            break;
          }
          if (outcome == _MediaOutcome.transient) {
            error = 'Could not upload photos — will retry.';
            break;
          }
        }
      }

      for (final path in await store.purgeSent(_now().subtract(const Duration(days: sentRetentionDays)))) {
        await mediaFiles.delete(path);
      }

      final pending = await store.pendingCount(userId);
      await store.recordRun(startedAt: startedAt, finishedAt: _now(), sent: sent, failed: failed, pending: pending,
          error: authExpired ? 'Session expired' : error);
      return SyncReport(sent: sent, failed: failed, pending: pending, authExpired: authExpired, error: error, finishedAt: _now());
    } finally {
      _running = false;
    }
  }

  Future<({int failed, bool authExpired, String? transientError})> _sendData(List<Submission> chunk) async {
    final uuids = chunk.map((s) => s.clientUuid).toList();
    await store.markSyncing(uuids);

    final payloads = <SubmissionPayload>[];
    for (final s in chunk) {
      payloads.add(SubmissionPayload(
        clientUuid: s.clientUuid,
        formId: s.formId,
        formVersion: s.formVersion,
        collectedAt: s.startedAt,
        deviceId: deviceId,
        appVersion: appVersion,
        lat: s.lat,
        lng: s.lng,
        data: s.payload ?? s.data,
        media: [for (final m in await store.media(s.clientUuid)) m.reference],
      ));
    }

    final List<BatchItemResult> results;
    try {
      results = await api.submitBatch(payloads);
    } on AuthExpiredException {
      await store.revertToFinalized(uuids);
      return (failed: 0, authExpired: true, transientError: null);
    } on ApiException catch (e) {
      if (e.transient) {
        for (final s in chunk) {
          await _retryLater(s, e.message, e.retryAfter);
        }
        return (failed: 0, authExpired: false, transientError: e.message);
      }
      // The whole batch was refused (e.g. 422 on the request itself).
      for (final uuid in uuids) {
        await store.markFailed(uuid, e.message);
      }
      return (failed: uuids.length, authExpired: false, transientError: null);
    }

    var failed = 0;
    final byUuid = {for (final r in results) r.clientUuid: r};
    for (final s in chunk) {
      final r = byUuid[s.clientUuid];
      if (r == null) {
        await _retryLater(s, 'The server did not confirm this submission.', null);
      } else if (r.isStored) {
        await store.markDataAccepted(s.clientUuid);
      } else {
        await store.markFailed(s.clientUuid, r.reason ?? 'Rejected by the server.');
        failed++;
      }
    }
    return (failed: failed, authExpired: false, transientError: null);
  }

  Future<_MediaOutcome> _sendMedia(Submission s) async {
    await store.markSyncing([s.clientUuid]);
    for (final m in await store.media(s.clientUuid)) {
      if (m.uploaded) continue;
      final bytes = await mediaFiles.read(m.path);
      if (bytes == null) {
        await store.markFailed(s.clientUuid, 'The photo for "${m.fieldName}" is missing from this device. Retake it and finalize again.');
        return _MediaOutcome.failed;
      }
      try {
        await api.uploadMedia(s.clientUuid, m.reference, bytes);
        await store.markMediaUploaded(m.fileName);
      } on AuthExpiredException {
        await store.revertToFinalized([s.clientUuid]);
        return _MediaOutcome.authExpired;
      } on ApiException catch (e) {
        if (e.transient) {
          await _retryLater(s, e.message, e.retryAfter);
          return _MediaOutcome.transient;
        }
        await store.markFailed(s.clientUuid, 'Photo "${m.fieldName}" was refused: ${e.message}');
        return _MediaOutcome.failed;
      }
    }
    await store.markSent(s.clientUuid, _now());
    return _MediaOutcome.sent;
  }

  Future<void> _retryLater(Submission s, String reason, Duration? retryAfter) {
    final attempts = s.attempts + 1;
    return store.scheduleRetry(
      s.clientUuid,
      attempts: attempts,
      nextAttemptAt: _now().add(retryDelay(attempts, retryAfter: retryAfter)),
      reason: reason,
    );
  }
}

enum _MediaOutcome { sent, failed, transient, authExpired }
