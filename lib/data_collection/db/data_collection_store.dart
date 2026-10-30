import 'dart:convert';
import 'package:sqflite/sqflite.dart';

import '../../db/database_helper.dart';
import '../models/api_models.dart';
import '../models/submission.dart';

// All reads/writes of the dc_* tables. Plain SQL over the app's single
// SQLite database; it takes the Database it works on so tests (and the
// background sync isolate) can hand it their own.
class DataCollectionStore {
  DataCollectionStore(this.db);

  final Database db;

  static Future<DataCollectionStore> open() async => DataCollectionStore(await DatabaseHelper.instance.database);

  // ── Forms ──

  // Mirrors GET /forms: adds/updates what's assigned, removes what no
  // longer is. Cached schemas stay, so existing drafts still open.
  Future<void> saveFormListing(List<RemoteForm> forms) async {
    await db.transaction((txn) async {
      final ids = forms.map((f) => f.id).toList();
      if (ids.isEmpty) {
        await txn.delete('dc_forms');
      } else {
        await txn.delete('dc_forms', where: 'formId NOT IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
      }
      for (final f in forms) {
        final updated = await txn.update(
          'dc_forms',
          {'title': f.title, 'latestVersion': f.version, 'latestChecksum': f.checksum, 'updatedAt': f.updatedAt?.toIso8601String()},
          where: 'formId = ?',
          whereArgs: [f.id],
        );
        if (updated == 0) {
          await txn.insert('dc_forms', {
            'formId': f.id,
            'title': f.title,
            'latestVersion': f.version,
            'latestChecksum': f.checksum,
            'updatedAt': f.updatedAt?.toIso8601String(),
          });
        }
      }
    });
  }

  // From GET /sync/status: only flags newer versions, never adds forms.
  Future<void> markLatestVersions(List<RemoteForm> forms) async {
    final batch = db.batch();
    for (final f in forms) {
      batch.update('dc_forms', {'latestVersion': f.version, 'latestChecksum': f.checksum}, where: 'formId = ?', whereArgs: [f.id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> saveSchema(RemoteForm form, String schemaJson, DateTime now) async {
    await db.transaction((txn) async {
      await txn.insert(
        'dc_form_schemas',
        {'formId': form.id, 'version': form.version, 'checksum': form.checksum, 'schemaJson': schemaJson, 'downloadedAt': now.toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.update('dc_forms', {'cachedVersion': form.version, 'cachedChecksum': form.checksum}, where: 'formId = ?', whereArgs: [form.id]);
    });
  }

  // Forms whose cached schema is missing or older than the server's.
  Future<List<RemoteForm>> formsNeedingDownload() async {
    final rows = await db.query(
      'dc_forms',
      where: 'cachedVersion IS NULL OR cachedVersion != latestVersion OR IFNULL(cachedChecksum, \'\') != IFNULL(latestChecksum, \'\')',
    );
    return [
      for (final r in rows)
        RemoteForm(id: r['formId'] as int, title: r['title'] as String? ?? '', version: r['latestVersion'] as String? ?? '', checksum: r['latestChecksum'] as String?),
    ];
  }

  Future<List<Map<String, dynamic>>> forms() => db.query('dc_forms', orderBy: 'title COLLATE NOCASE');

  Future<String?> schemaJson(int formId, String version) async {
    final rows = await db.query('dc_form_schemas', columns: ['schemaJson'], where: 'formId = ? AND version = ?', whereArgs: [formId, version], limit: 1);
    return rows.isEmpty ? null : rows.first['schemaJson'] as String?;
  }

  Future<void> clearFormListing() => db.delete('dc_forms');

  // ── Submissions ──

  Future<void> insertSubmission(Submission s) => db.insert('dc_submissions', s.toRow());

  Future<Submission?> submission(String uuid) async {
    final rows = await db.query('dc_submissions', where: 'clientUuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : Submission.fromRow(rows.first);
  }

  Future<List<Submission>> submissions({required int ownerUserId, required Set<SubmissionStatus> statuses, int? formId}) async {
    final rows = await db.query(
      'dc_submissions',
      where: 'ownerUserId = ? AND status IN (${List.filled(statuses.length, '?').join(',')})${formId != null ? ' AND formId = ?' : ''}',
      whereArgs: [ownerUserId, ...statuses.map((s) => s.name), if (formId != null) formId],
      orderBy: 'updatedAt DESC',
    );
    return rows.map(Submission.fromRow).toList();
  }

  // Autosave. Editing a finalized/failed submission moves it back to draft
  // so a half-edited version can't be picked up by sync.
  Future<void> saveDraftData(String uuid, Map<String, dynamic> data, DateTime now) => db.update(
        'dc_submissions',
        {'data': jsonEncode(data), 'status': SubmissionStatus.draft.name, 'payload': null, 'errorReason': null, 'updatedAt': now.toIso8601String()},
        where: 'clientUuid = ? AND status IN (?, ?, ?)',
        whereArgs: [uuid, SubmissionStatus.draft.name, SubmissionStatus.finalized.name, SubmissionStatus.failed.name],
      );

  Future<void> finalize(String uuid, {required Map<String, dynamic> data, required Map<String, dynamic> payload, double? lat, double? lng, required DateTime now}) =>
      db.update(
        'dc_submissions',
        {
          'status': SubmissionStatus.finalized.name,
          'data': jsonEncode(data),
          'payload': jsonEncode(payload),
          'lat': lat,
          'lng': lng,
          'finalizedAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
          'attempts': 0,
          'nextAttemptAt': null,
          'errorReason': null,
        },
        where: 'clientUuid = ?',
        whereArgs: [uuid],
      );

  // "Retry" on a failed submission: back in the queue, due immediately.
  Future<void> requeue(String uuid, DateTime now) => db.update(
        'dc_submissions',
        {'status': SubmissionStatus.finalized.name, 'attempts': 0, 'nextAttemptAt': null, 'errorReason': null, 'updatedAt': now.toIso8601String()},
        where: 'clientUuid = ? AND status = ?',
        whereArgs: [uuid, SubmissionStatus.failed.name],
      );

  // Returns the media paths so the caller can delete the files.
  Future<List<String>> deleteSubmission(String uuid) async {
    final paths = (await media(uuid)).map((m) => m.path).toList();
    await db.transaction((txn) async {
      await txn.delete('dc_media', where: 'clientUuid = ?', whereArgs: [uuid]);
      await txn.delete('dc_submissions', where: 'clientUuid = ?', whereArgs: [uuid]);
    });
    return paths;
  }

  Future<Map<SubmissionStatus, int>> statusCounts(int ownerUserId, {int? formId}) async {
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS c FROM dc_submissions WHERE ownerUserId = ?${formId != null ? ' AND formId = ?' : ''} GROUP BY status',
      [ownerUserId, if (formId != null) formId],
    );
    return {
      for (final r in rows)
        SubmissionStatus.values.firstWhere((s) => s.name == r['status'], orElse: () => SubmissionStatus.draft): r['c'] as int,
    };
  }

  // Finalized-or-later submissions per form: today, this week (from Monday), total.
  Future<Map<String, int>> collectedCounts(int ownerUserId, int formId, DateTime now) async {
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final rows = await db.rawQuery(
      '''SELECT
           SUM(CASE WHEN finalizedAt >= ? THEN 1 ELSE 0 END) AS today,
           SUM(CASE WHEN finalizedAt >= ? THEN 1 ELSE 0 END) AS week,
           COUNT(*) AS total
         FROM dc_submissions WHERE ownerUserId = ? AND formId = ? AND status != ?''',
      [today.toIso8601String(), weekStart.toIso8601String(), ownerUserId, formId, SubmissionStatus.draft.name],
    );
    final r = rows.first;
    return {'today': (r['today'] as int?) ?? 0, 'week': (r['week'] as int?) ?? 0, 'total': (r['total'] as int?) ?? 0};
  }

  Future<int> pendingCount(int ownerUserId) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM dc_submissions WHERE ownerUserId = ? AND status IN (?, ?)',
      [ownerUserId, SubmissionStatus.finalized.name, SubmissionStatus.syncing.name],
    );
    return rows.first['c'] as int;
  }

  // ── Sync queue ──

  // Includes 'syncing' so a run interrupted mid-way (app killed) is resumed.
  Future<List<Submission>> dueForSync(int ownerUserId, DateTime now, {bool force = false}) async {
    final rows = await db.query(
      'dc_submissions',
      where: 'ownerUserId = ? AND status IN (?, ?)${force ? '' : ' AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)'}',
      whereArgs: [ownerUserId, SubmissionStatus.finalized.name, SubmissionStatus.syncing.name, if (!force) now.toIso8601String()],
      orderBy: 'finalizedAt',
    );
    return rows.map(Submission.fromRow).toList();
  }

  Future<void> _setStatus(Iterable<String> uuids, Map<String, Object?> values) async {
    final batch = db.batch();
    for (final uuid in uuids) {
      batch.update('dc_submissions', values, where: 'clientUuid = ?', whereArgs: [uuid]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> markSyncing(Iterable<String> uuids) => _setStatus(uuids, {'status': SubmissionStatus.syncing.name});

  Future<void> revertToFinalized(Iterable<String> uuids) => _setStatus(uuids, {'status': SubmissionStatus.finalized.name});

  Future<void> markDataAccepted(String uuid) => _setStatus([uuid], {'dataAccepted': 1});

  Future<void> markFailed(String uuid, String reason) =>
      _setStatus([uuid], {'status': SubmissionStatus.failed.name, 'errorReason': reason, 'nextAttemptAt': null});

  Future<void> scheduleRetry(String uuid, {required int attempts, required DateTime nextAttemptAt, required String reason}) => _setStatus(
        [uuid],
        {'status': SubmissionStatus.finalized.name, 'attempts': attempts, 'nextAttemptAt': nextAttemptAt.toIso8601String(), 'errorReason': reason},
      );

  Future<void> markSent(String uuid, DateTime now) => _setStatus(
        [uuid],
        {'status': SubmissionStatus.sent.name, 'sentAt': now.toIso8601String(), 'attempts': 0, 'nextAttemptAt': null, 'errorReason': null},
      );

  // Removes sent submissions older than the cutoff; returns media paths to delete.
  Future<List<String>> purgeSent(DateTime cutoff) async {
    final rows = await db.query('dc_submissions', columns: ['clientUuid'], where: 'status = ? AND sentAt < ?', whereArgs: [SubmissionStatus.sent.name, cutoff.toIso8601String()]);
    final paths = <String>[];
    for (final r in rows) {
      paths.addAll(await deleteSubmission(r['clientUuid'] as String));
    }
    return paths;
  }

  // ── Ownership (one device, several users) ──

  // Unsent submissions that belong to someone other than userId.
  Future<List<({int ownerUserId, String ownerName, int count})>> queuedForOtherOwners(int userId) async {
    final rows = await db.rawQuery(
      'SELECT ownerUserId, ownerName, COUNT(*) AS c FROM dc_submissions WHERE ownerUserId != ? AND status != ? GROUP BY ownerUserId, ownerName',
      [userId, SubmissionStatus.sent.name],
    );
    return [for (final r in rows) (ownerUserId: r['ownerUserId'] as int, ownerName: r['ownerName'] as String? ?? '', count: r['c'] as int)];
  }

  // Deletes every unsent submission of that owner; returns media paths.
  Future<List<String>> discardQueue(int ownerUserId) async {
    final rows = await db.query('dc_submissions', columns: ['clientUuid'], where: 'ownerUserId = ? AND status != ?', whereArgs: [ownerUserId, SubmissionStatus.sent.name]);
    final paths = <String>[];
    for (final r in rows) {
      paths.addAll(await deleteSubmission(r['clientUuid'] as String));
    }
    return paths;
  }

  // ── Media ──

  Future<void> insertMedia(MediaRecord m) => db.insert('dc_media', m.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<MediaRecord>> media(String uuid) async =>
      (await db.query('dc_media', where: 'clientUuid = ?', whereArgs: [uuid])).map(MediaRecord.fromRow).toList();

  Future<MediaRecord?> mediaFile(String fileName) async {
    final rows = await db.query('dc_media', where: 'fileName = ?', whereArgs: [fileName], limit: 1);
    return rows.isEmpty ? null : MediaRecord.fromRow(rows.first);
  }

  Future<void> markMediaUploaded(String fileName) => db.update('dc_media', {'uploaded': 1}, where: 'fileName = ?', whereArgs: [fileName]);

  Future<void> deleteMedia(String fileName) => db.delete('dc_media', where: 'fileName = ?', whereArgs: [fileName]);

  // ── Sync history ──

  Future<void> recordRun({required DateTime startedAt, required DateTime finishedAt, required int sent, required int failed, required int pending, String? error}) =>
      db.insert('dc_sync_runs', {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'sent': sent,
        'failed': failed,
        'pending': pending,
        'error': error,
      });

  Future<List<Map<String, dynamic>>> recentRuns({int limit = 20}) => db.query('dc_sync_runs', orderBy: 'id DESC', limit: limit);
}
