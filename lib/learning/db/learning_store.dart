import 'dart:convert';
import 'package:sqflite/sqflite.dart';

import '../../db/database_helper.dart';
import '../models/learning_models.dart';

enum SetupStatus { pending, sent, failed }

// One thing a teacher created on this device, waiting to be uploaded by
// POST /learning/setup. kind: course (with all its topics) | cohort |
// student | enrollment. json is the item exactly as the endpoint takes it.
class SetupItem {
  SetupItem({required this.clientUuid, required this.kind, required this.cohortUuid, required this.json, this.status = SetupStatus.pending, this.errorReason});

  final String clientUuid;
  final String kind;
  final String cohortUuid; // the class it belongs to, so its sessions wait for it
  final Map<String, dynamic> json;
  final SetupStatus status;
  final String? errorReason;
}

// The lc_* tables: classes as downloaded or created here, sessions recorded
// here (the session queue) and setup items (the setup queue).
class LearningStore {
  LearningStore(this.db);

  final Database db;

  static Future<LearningStore> open() async => LearningStore(await DatabaseHelper.instance.database);

  // ── Classes (cohorts) ──

  Future<void> saveCohort(Map<String, dynamic> json, int ownerUserId) => db.insert(
        'lc_cohorts',
        {
          'cohortUuid': json['client_uuid'],
          'ownerUserId': ownerUserId,
          'checksum': json['checksum'],
          'json': jsonEncode(json),
          'downloadedAt': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // A download replaces the cached class, then anything created here but not
  // yet uploaded (new topics, enrolled students) is laid back on top so it
  // doesn't vanish from the screen.
  Future<void> saveDownloadedCohort(Map<String, dynamic> json, int ownerUserId) async {
    final merged = Map<String, dynamic>.of(json);
    final cohortUuid = json['client_uuid'] as String;
    final roster = [...((merged['roster'] as List?) ?? const [])];
    final course = Map<String, dynamic>.of((merged['course'] as Map?)?.cast<String, dynamic>() ?? {});
    final topics = [...((course['topics'] as List?) ?? const [])];

    for (final item in await setupItems(cohortUuid: cohortUuid, onlyUnsent: true)) {
      if (item.kind == 'enrollment' && !roster.any((r) => (r as Map)['client_uuid'] == item.clientUuid)) {
        roster.add(item.json['_roster_entry']);
      }
      if (item.kind == 'course' || item.kind == 'cohort') {
        for (final t in ((item.json['topics'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
          if (!topics.any((x) => (x as Map)['client_uuid'] == t['client_uuid'])) topics.add(t);
        }
      }
    }
    course['topics'] = topics;
    merged['course'] = course;
    merged['roster'] = roster;
    await saveCohort(merged, ownerUserId);
  }

  Future<void> removeCohorts(Iterable<String> uuids) async {
    for (final uuid in uuids) {
      await db.delete('lc_cohorts', where: 'cohortUuid = ?', whereArgs: [uuid]);
    }
  }

  Future<List<LearningCohort>> cohorts(int ownerUserId) async {
    final rows = await db.query('lc_cohorts', where: 'ownerUserId = ?', whereArgs: [ownerUserId]);
    final list = rows.map((r) => LearningCohort(jsonDecode(r['json'] as String) as Map<String, dynamic>)).toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  Future<LearningCohort?> cohort(String uuid) async {
    final rows = await db.query('lc_cohorts', where: 'cohortUuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : LearningCohort(jsonDecode(rows.first['json'] as String) as Map<String, dynamic>);
  }

  // Server ids of downloaded classes → checksum, for sync-status. Classes
  // only created here have no server id yet and aren't included.
  Future<Map<int, String>> checksums(int ownerUserId) async {
    final out = <int, String>{};
    for (final c in await cohorts(ownerUserId)) {
      final id = c.json['id'];
      if (id is int) out[id] = c.checksum;
    }
    return out;
  }

  Future<void> clearCohorts() => db.delete('lc_cohorts');

  // ── Setup queue ──

  Future<void> saveSetupItem(SetupItem item, {required int ownerUserId, required String ownerName}) => db.insert(
        'lc_setup_items',
        {
          'clientUuid': item.clientUuid,
          'kind': item.kind,
          'cohortUuid': item.cohortUuid,
          'json': jsonEncode(item.json),
          'status': SetupStatus.pending.name,
          'errorReason': null,
          'ownerUserId': ownerUserId,
          'ownerName': ownerName,
          'createdAt': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<SetupItem>> setupItems({int? ownerUserId, String? cohortUuid, bool onlyUnsent = false, bool onlyPending = false}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (ownerUserId != null) {
      where.add('ownerUserId = ?');
      args.add(ownerUserId);
    }
    if (cohortUuid != null) {
      where.add('cohortUuid = ?');
      args.add(cohortUuid);
    }
    if (onlyUnsent) where.add("status != 'sent'");
    if (onlyPending) where.add("status = 'pending'");
    final rows = await db.query('lc_setup_items', where: where.isEmpty ? null : where.join(' AND '), whereArgs: args, orderBy: 'createdAt');
    return [
      for (final r in rows)
        SetupItem(
          clientUuid: r['clientUuid'] as String,
          kind: r['kind'] as String,
          cohortUuid: r['cohortUuid'] as String,
          json: jsonDecode(r['json'] as String) as Map<String, dynamic>,
          status: SetupStatus.values.firstWhere((s) => s.name == r['status'], orElse: () => SetupStatus.pending),
          errorReason: r['errorReason'] as String?,
        ),
    ];
  }

  Future<void> markSetup(String uuid, SetupStatus status, {String? reason}) =>
      db.update('lc_setup_items', {'status': status.name, 'errorReason': reason}, where: 'clientUuid = ?', whereArgs: [uuid]);

  // Classes with setup not yet accepted by the CRM — their sessions wait.
  Future<Set<String>> cohortsAwaitingSetup(int ownerUserId) async {
    final rows = await db.rawQuery(
      "SELECT DISTINCT cohortUuid FROM lc_setup_items WHERE ownerUserId = ? AND status != 'sent'",
      [ownerUserId],
    );
    return {for (final r in rows) r['cohortUuid'] as String};
  }

  // The student was already in this class on the server under another
  // uuid: use the server's everywhere on this device.
  Future<void> replaceEnrollmentUuid(String cohortUuid, String from, String to) async {
    final c = await cohort(cohortUuid);
    if (c != null) {
      final json = Map<String, dynamic>.of(c.json);
      json['roster'] = [
        for (final r in c.roster) r.uuid == from ? (Map<String, dynamic>.of(r.json)..['client_uuid'] = to) : r.json,
      ];
      final row = await db.query('lc_cohorts', columns: ['ownerUserId'], where: 'cohortUuid = ?', whereArgs: [cohortUuid]);
      await saveCohort(json, row.first['ownerUserId'] as int);
    }
    final rows = await db.query('lc_session_records', where: 'cohortUuid = ?', whereArgs: [cohortUuid]);
    for (final r in rows) {
      await db.update(
        'lc_session_records',
        {
          'attendance': (r['attendance'] as String).replaceAll('"$from"', '"$to"'),
          'topicProgress': (r['topicProgress'] as String).replaceAll('"$from"', '"$to"'),
        },
        where: 'clientUuid = ?',
        whereArgs: [r['clientUuid']],
      );
    }
  }

  // ── Session records ──

  Future<void> saveRecord(LocalSessionRecord r) => db.insert('lc_session_records', r.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<LocalSessionRecord?> record(String uuid) async {
    final rows = await db.query('lc_session_records', where: 'clientUuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : LocalSessionRecord.fromRow(rows.first);
  }

  Future<List<LocalSessionRecord>> records({required int ownerUserId, String? cohortUuid}) async {
    final rows = await db.query(
      'lc_session_records',
      where: 'ownerUserId = ?${cohortUuid != null ? ' AND cohortUuid = ?' : ''}',
      whereArgs: [ownerUserId, if (cohortUuid != null) cohortUuid],
      orderBy: 'heldOn DESC, updatedAt DESC',
    );
    return rows.map(LocalSessionRecord.fromRow).toList();
  }

  Future<void> deleteRecord(String uuid) => db.delete('lc_session_records', where: 'clientUuid = ?', whereArgs: [uuid]);

  Future<int> pendingCount(int ownerUserId) async {
    final rows = await db.rawQuery(
      "SELECT (SELECT COUNT(*) FROM lc_session_records WHERE ownerUserId = ? AND status IN ('finalized', 'syncing'))"
      " + (SELECT COUNT(*) FROM lc_setup_items WHERE ownerUserId = ? AND status = 'pending') AS c",
      [ownerUserId, ownerUserId],
    );
    return rows.first['c'] as int;
  }

  // ── Session sync queue ──

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
    final rows = await db.rawQuery('''
      SELECT ownerUserId, ownerName, SUM(c) AS c FROM (
        SELECT ownerUserId, ownerName, COUNT(*) AS c FROM lc_session_records WHERE ownerUserId != ? AND status != 'sent' GROUP BY ownerUserId, ownerName
        UNION ALL
        SELECT ownerUserId, ownerName, COUNT(*) AS c FROM lc_setup_items WHERE ownerUserId != ? AND status != 'sent' GROUP BY ownerUserId, ownerName
      ) GROUP BY ownerUserId, ownerName
    ''', [userId, userId]);
    return [for (final r in rows) (ownerUserId: r['ownerUserId'] as int, ownerName: r['ownerName'] as String? ?? '', count: (r['c'] as num).toInt())];
  }

  Future<void> discardQueue(int ownerUserId) async {
    await db.delete('lc_session_records', where: "ownerUserId = ? AND status != 'sent'", whereArgs: [ownerUserId]);
    await db.delete('lc_setup_items', where: "ownerUserId = ? AND status != 'sent'", whereArgs: [ownerUserId]);
  }
}
