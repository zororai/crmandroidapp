import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/api/data_collection_api.dart';
import 'package:yazcrm_beneficiary_flutter/db/database_helper.dart';
import 'package:yazcrm_beneficiary_flutter/learning/api/learning_api.dart';
import 'package:yazcrm_beneficiary_flutter/learning/db/learning_store.dart';
import 'package:yazcrm_beneficiary_flutter/learning/models/learning_models.dart';
import 'package:yazcrm_beneficiary_flutter/learning/sync/learning_sync.dart';

class FakeLearningApi implements LearningApi {
  final batches = <List<Map<String, dynamic>>>[];
  Object? Function()? failBatch;
  Map<String, Map<String, dynamic>> results = {}; // uuid → result override
  List<Map<String, dynamic>> cohorts = [];
  ({List<int> changed, List<int> removed}) status = (changed: <int>[], removed: <int>[]);
  List<int>? lastFetchIds;

  @override
  Future<List<Map<String, dynamic>>> submitBatch(List<Map<String, dynamic>> sessions) async {
    batches.add(sessions);
    final error = failBatch?.call();
    if (error != null) throw error;
    return [for (final s in sessions) results[s['client_uuid']] ?? {'client_uuid': s['client_uuid'], 'status': 'accepted'}];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchCohorts({List<int>? ids}) async {
    lastFetchIds = ids;
    return ids == null ? cohorts : cohorts.where((c) => ids.contains(c['id'])).toList();
  }

  @override
  Future<({List<int> changed, List<int> removed})> syncStatus(Map<int, String> checksums) async => status;

  @override
  Future<Map<String, dynamic>> performance() async => {};
}

void main() {
  sqfliteFfiInit();

  late Database db;
  late LearningStore store;
  late FakeLearningApi api;
  var now = DateTime(2026, 11, 2, 12);

  LearningSync sync({int userId = 1}) => LearningSync(store: store, api: api, userId: userId, deviceId: 'device-1', now: () => now);

  Future<void> addFinished(String uuid, {int owner = 1, RecordStatus status = RecordStatus.finalized}) => store.saveRecord(LocalSessionRecord(
        clientUuid: uuid,
        cohortId: 5,
        cohortSessionId: 41,
        heldOn: '2026-11-02',
        startedAt: DateTime(2026, 11, 2, 9),
        endedAt: DateTime(2026, 11, 2, 11),
        topics: [{'topic_id': 7, 'coverage': 'full', 'note': null}],
        attendance: [{'enrollment_id': 88, 'status': 'present', 'arrived_at': null, 'reason': null, 'marked_at': '2026-11-02T07:05:00Z'}],
        topicProgress: [{'enrollment_id': 88, 'topic_id': 7, 'status': 'completed', 'score': 72.5}],
        status: status,
        ownerUserId: owner,
        ownerName: 'User $owner',
      ));

  Future<RecordStatus> statusOf(String uuid) async => (await store.record(uuid))!.status;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 1, onCreate: (db, _) => createLearningTables(db)));
    store = LearningStore(db);
    api = FakeLearningApi();
    now = DateTime(2026, 11, 2, 12);
  });

  tearDown(() => db.close());

  test('finished sessions are sent with the contract payload', () async {
    await addFinished('a');
    final report = await sync().run();

    expect(report.sent, 1);
    expect(await statusOf('a'), RecordStatus.sent);
    final p = api.batches.single.single;
    expect(p.keys, containsAll(['client_uuid', 'cohort_id', 'cohort_session_id', 'held_on', 'started_at', 'ended_at', 'device_id', 'app_version', 'topics', 'attendance', 'topic_progress']));
    expect(p['held_on'], '2026-11-02');
    expect((p['attendance'] as List).single['status'], 'present');
  });

  test('drafts are never sent', () async {
    await addFinished('d', status: RecordStatus.draft);
    await sync().run();
    expect(api.batches, isEmpty);
  });

  test('duplicate and updated count as delivered; warnings are kept', () async {
    await addFinished('dup');
    await addFinished('upd');
    api.results = {
      'dup': {'client_uuid': 'dup', 'status': 'duplicate'},
      'upd': {'client_uuid': 'upd', 'status': 'updated', 'warnings': [{'code': 'stale_attendance'}]},
    };
    await sync().run();
    expect(await statusOf('dup'), RecordStatus.sent);
    expect((await store.record('upd'))!.warnings.single['code'], 'stale_attendance');
  });

  test('rejected sessions fail with a readable reason; retryable ones are retried later', () async {
    await addFinished('bad');
    await addFinished('later');
    api.results = {
      'bad': {'client_uuid': 'bad', 'status': 'rejected', 'reason': 'foreign_enrollment'},
      'later': {'client_uuid': 'later', 'status': 'rejected', 'reason': 'server_error', 'retryable': true},
    };
    final report = await sync().run();

    expect(report.failed, 1);
    final bad = (await store.record('bad'))!;
    expect(bad.status, RecordStatus.failed);
    expect(bad.errorReason, contains('not in this cohort'));
    final later = (await store.record('later'))!;
    expect(later.status, RecordStatus.finalized);
    expect(later.nextAttemptAt, now.add(const Duration(seconds: 30)));
  });

  test('batches hold at most 20 sessions', () async {
    for (var i = 0; i < 45; i++) {
      await addFinished('s$i');
    }
    await sync().run();
    expect(api.batches.map((b) => b.length), [20, 20, 5]);
  });

  test('network errors back off and keep the queue', () async {
    await addFinished('a');
    api.failBatch = () => ApiException('offline', transient: true);
    final report = await sync().run();

    expect(report.error, 'offline');
    expect(await statusOf('a'), RecordStatus.finalized);

    api.failBatch = null;
    now = now.add(const Duration(seconds: 10));
    await sync().run();
    expect(api.batches.length, 1, reason: 'still backing off');

    now = now.add(const Duration(seconds: 30));
    await sync().run();
    expect(await statusOf('a'), RecordStatus.sent);
  });

  test('401 stops the run and leaves sessions queued', () async {
    await addFinished('a');
    api.failBatch = () => AuthExpiredException();
    final report = await sync().run();

    expect(report.authExpired, isTrue);
    expect(await statusOf('a'), RecordStatus.finalized);
    expect((await store.record('a'))!.attempts, 0);
  });

  test("only the current user's sessions are sent", () async {
    await addFinished('mine', owner: 1);
    await addFinished('theirs', owner: 2);
    await sync(userId: 1).run();
    expect(api.batches.single.map((s) => s['client_uuid']), ['mine']);
    expect(await statusOf('theirs'), RecordStatus.finalized);
  });

  test('cohorts: full download, then only changed ones, removed ones dropped', () async {
    api.cohorts = [
      {'id': 5, 'name': 'A', 'checksum': 'x1'},
      {'id': 6, 'name': 'B', 'checksum': 'y1'},
    ];
    expect(await sync().refreshCohorts(), 2);
    expect((await store.cohorts(1)).map((c) => c.id), [5, 6]);

    api.cohorts = [{'id': 5, 'name': 'A2', 'checksum': 'x2'}];
    api.status = (changed: [5], removed: [6]);
    await sync().refreshCohorts(changedOnly: true);

    expect(api.lastFetchIds, [5]);
    final cohorts = await store.cohorts(1);
    expect(cohorts.map((c) => c.name), ['A2']);
  });

  test('sent sessions are purged after the retention period', () async {
    await addFinished('a');
    await sync().run();
    now = now.add(const Duration(days: 31));
    await sync().run();
    expect(await store.record('a'), isNull);
  });

  test('duration comes from start and end', () {
    final r = LocalSessionRecord(
      clientUuid: 'x', cohortId: 1, heldOn: '2026-11-02', ownerUserId: 1, ownerName: '',
      startedAt: DateTime(2026, 11, 2, 9, 5), endedAt: DateTime(2026, 11, 2, 10, 55),
    );
    expect(r.duration, const Duration(minutes: 110));
  });
}
