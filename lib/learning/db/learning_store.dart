import 'dart:convert';
import 'package:sqflite/sqflite.dart';

import '../../db/database_helper.dart';
import '../models/learning_models.dart';

// The lc_* tables: cohorts as last downloaded, and the sessions recorded on
// this device (which double as the sync queue).
class LearningStore {
  LearningStore(this.db);

  final Database db;

  static Future<LearningStore> open() async => LearningStore(await DatabaseHelper.instance.database);

  // ── Cohorts ──

  Future<void> saveCohort(Map<String, dynamic> json, int ownerUserId) => db.insert(
        'lc_cohorts',
        {
          'cohortId': json['id'],
          'ownerUserId': ownerUserId,
          'checksum': json['checksum'],
          'json': jsonEncode(json),
          'downloadedAt': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> removeCohorts(Iterable<int> ids) async {
    for (final id in ids) {
      await db.delete('lc_cohorts', where: 'cohortId = ?', whereArgs: [id]);
    }
  }

  Future<List<LearningCohort>> cohorts(int ownerUserId) async {
    final rows = await db.query('lc_cohorts', where: 'ownerUserId = ?', whereArgs: [ownerUserId]);
    final list = rows.map((r) => LearningCohort(jsonDecode(r['json'] as String) as Map<String, dynamic>)).toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  Future<LearningCohort?> cohort(int id) async {
    final rows = await db.query('lc_cohorts', where: 'cohortId = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : LearningCohort(jsonDecode(rows.first['json'] as String) as Map<String, dynamic>);
  }

  // cohortId → checksum, for GET /learning/sync-status?checksums=…
  Future<Map<int, String>> checksums(int ownerUserId) async {
    final rows = await db.query('lc_cohorts', columns: ['cohortId', 'checksum'], where: 'ownerUserId = ?', whereArgs: [ownerUserId]);
    return {for (final r in rows) r['cohortId'] as int: r['checksum'] as String? ?? ''};
  }

  Future<void> clearCohorts() => db.delete('lc_cohorts');

  // ── Session records ──

  Future<void> saveRecord(LocalSessionRecord r) => db.insert('lc_session_records', r.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<LocalSessionRecord?> record(String uuid) async {
    final rows = await db.query('lc_session_records', where: 'clientUuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : LocalSessionRecord.fromRow(rows.first);
  }

  Future<List<LocalSessionRecord>> records({required int ownerUserId, int? cohortId}) async {
    final rows = await db.query(
      'lc_session_records',
      where: 'ownerUserId = ?${cohortId != null ? ' AND cohortId = ?' : ''}',
      whereArgs: [ownerUserId, if (cohortId != null) cohortId],
      orderBy: 'heldOn DESC, updatedAt DESC',
    );
    return rows.map(LocalSessionRecord.fromRow).toList();
  }

  Future<void> deleteRecord(String uuid) => db.delete('lc_session_records', where: 'clientUuid = ?', whereArgs: [uuid]);

  Future<int> pendingCount(int ownerUserId) async {
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM lc_session_records WHERE ownerUserId = ? AND status IN ('finalized', 'syncing')",
      [ownerUserId],
    );
    return rows.first['c'] as int;
  }

  // ── Sync queue ──

  Future<List<LocalSessionRecord>> dueForSync(int ownerUserId, DateTime now, {bool force = false}) async {
    final rows = await db.query(
      'lc_session_records',
      where: "ownerUserId = ? AND status IN ('finalized', 'syncing')${force ? '' : ' AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)'}",
      whereArgs: [ownerUserId, if (!force) now.toIso8601String()],
      orderBy: 'heldOn',
    );
    return rows.map(LocalSessionRecord.fromRow).toList();
  }

  Future<void> _update(Iterable<String> uuids, Map<String, Object?> values) async {
    final batch = db.batch();
    for (final uuid in uuids) {
      batch.update('lc_session_records', values, where: 'clientUuid = ?', whereArgs: [uuid]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> markSyncing(Iterable<String> uuids) => _update(uuids, {'status': RecordStatus.syncing.name});

  Future<void> revertToFinalized(Iterable<String> uuids) => _update(uuids, {'status': RecordStatus.finalized.name});

  Future<void> markSent(String uuid, List<Map<String, dynamic>> warnings, DateTime now) => _update([uuid], {
        'status': RecordStatus.sent.name,
        'warnings': jsonEncode(warnings),
        'errorReason': null,
        'attempts': 0,
        'nextAttemptAt': null,
        'sentAt': now.toIso8601String(),
      });

  Future<void> markFailed(String uuid, String reason) =>
      _update([uuid], {'status': RecordStatus.failed.name, 'errorReason': reason, 'nextAttemptAt': null});

  Future<void> scheduleRetry(String uuid, {required int attempts, required DateTime nextAttemptAt, required String reason}) => _update(
        [uuid],
        {'status': RecordStatus.finalized.name, 'attempts': attempts, 'nextAttemptAt': nextAttemptAt.toIso8601String(), 'errorReason': reason},
      );

  // Sent records are history on the server; keep them a while, then purge.
  Future<void> purgeSent(DateTime cutoff) =>
      db.delete('lc_session_records', where: "status = 'sent' AND sentAt < ?", whereArgs: [cutoff.toIso8601String()]);

  // ── Ownership ──

  Future<List<({int ownerUserId, String ownerName, int count})>> queuedForOtherOwners(int userId) async {
    final rows = await db.rawQuery(
      "SELECT ownerUserId, ownerName, COUNT(*) AS c FROM lc_session_records WHERE ownerUserId != ? AND status != 'sent' GROUP BY ownerUserId, ownerName",
      [userId],
    );
    return [for (final r in rows) (ownerUserId: r['ownerUserId'] as int, ownerName: r['ownerName'] as String? ?? '', count: r['c'] as int)];
  }

  Future<void> discardQueue(int ownerUserId) =>
      db.delete('lc_session_records', where: "ownerUserId = ? AND status != 'sent'", whereArgs: [ownerUserId]);
}
