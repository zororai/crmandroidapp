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
  final setups = <Map<String, List<Map<String, dynamic>>>>[];
  final calls = <String>[];
  Object? Function()? failBatch;
  Object? Function()? failSetup;
  Map<String, Map<String, dynamic>> results = {}; // uuid → session result override
  Map<String, Map<String, dynamic>> setupResults = {}; // uuid → setup result override
  List<Map<String, dynamic>> cohorts = [];
  ({List<int> changed, List<int> removed}) status = (changed: <int>[], removed: <int>[]);
  List<int>? lastFetchIds;

  @override
  Future<List<Map<String, dynamic>>> submitBatch(List<Map<String, dynamic>> sessions) async {
    calls.add('sessions');
    batches.add(sessions);
    final error = failBatch?.call();
    if (error != null) throw error;
    return [for (final s in sessions) results[s['client_uuid']] ?? {'client_uuid': s['client_uuid'], 'status': 'accepted'}];
  }

  @override
  Future<List<Map<String, dynamic>>> setup(Map<String, List<Map<String, dynamic>>> payload) async {
    calls.add('setup');
    setups.add(payload);
    final error = failSetup?.call();
    if (error != null) throw error;
    final kinds = {'courses': 'course', 'cohorts': 'cohort', 'students': 'student', 'enrollments': 'enrollment'};
    return [
      for (final e in payload.entries)
        for (final item in e.value) ...[
          setupResults[item['client_uuid']] ?? {'kind': kinds[e.key], 'client_uuid': item['client_uuid'], 'status': 'accepted', 'id': 1},
          if (e.key == 'courses')
            for (final t in (item['topics'] as List).cast<Map<String, dynamic>>())
              setupResults[t['client_uuid']] ?? {'kind': 'topic', 'client_uuid': t['client_uuid'], 'status': 'accepted', 'id': 2},
        ],
    ];
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

  @override
  Future<List<Map<String, dynamic>>> searchBeneficiaries(String query) async => [];

  @override
  Future<List<Map<String, dynamic>>> catalogue() async => [];
}

void main() {
  sqfliteFfiInit();

  late Database db;
  late LearningStore store;
  late FakeLearningApi api;
  var now = DateTime(2026, 11, 2, 12);

  LearningSync sync({int userId = 1}) => LearningSync(store: store, api: api, userId: userId, deviceId: 'device-1', now: () => now);

  Future<void> addFinished(String uuid, {int owner = 1, String cohort = 'class-1', RecordStatus status = RecordStatus.finalized}) =>
      store.saveRecord(LocalSessionRecord(
        clientUuid: uuid,
        cohortUuid: cohort,
        cohortSessionId: 41,
        heldOn: '2026-11-02',
        startedAt: DateTime(2026, 11, 2, 9),
        endedAt: DateTime(2026, 11, 2, 11),
        topics: [{'topic_client_uuid': 'topic-1', 'coverage': 'full', 'note': null}],
        attendance: [{'enrollment_client_uuid': 'enr-1', 'status': 'present', 'arrived_at': null, 'reason': null, 'marked_at': '2026-11-02T07:05:00Z'}],
        topicProgress: [{'enrollment_client_uuid': 'enr-1', 'topic_client_uuid': 'topic-1', 'status': 'completed', 'score': 72.5}],
        status: status,
        ownerUserId: owner,
        ownerName: 'User $owner',
      ));

  Future<void> queue(String uuid, String kind, Map<String, dynamic> json, {String cohort = 'class-1', int owner = 1}) =>
      store.saveSetupItem(SetupItem(clientUuid: uuid, kind: kind, cohortUuid: cohort, json: {'client_uuid': uuid, ...json}), ownerUserId: owner, ownerName: 'User $owner');

  Future<RecordStatus> statusOf(String uuid) async => (await store.record(uuid))!.status;
  Future<SetupStatus> setupStatus(String uuid) async => (await store.setupItems()).firstWhere((i) => i.clientUuid == uuid).status;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: OpenDatabaseOptions(version: 1, onCreate: (db, _) => createLearningTables(db)));
    store = LearningStore(db);
    api = FakeLearningApi();
    now = DateTime(2026, 11, 2, 12);
  });

  tearDown(() => db.close());

  group('sessions', () {
    test('finished sessions are sent, referring to class, students and topics by uuid', () async {
      await addFinished('a');
      final report = await sync().run();

      expect(report.sent, 1);
      expect(await statusOf('a'), RecordStatus.sent);
      final p = api.batches.single.single;
      expect(p['cohort_client_uuid'], 'class-1');
      expect((p['attendance'] as List).single['enrollment_client_uuid'], 'enr-1');
      expect((p['topics'] as List).single['topic_client_uuid'], 'topic-1');
      expect((p['topic_progress'] as List).single['score'], 72.5);
      expect(p.keys, containsAll(['client_uuid', 'held_on', 'started_at', 'ended_at', 'device_id', 'app_version']));
    });

    test('drafts are never sent', () async {
      await addFinished('d', status: RecordStatus.draft);
      await sync().run();
      expect(api.batches, isEmpty);
    });

    test('duplicate and updated count as delivered; rejected fails with a readable reason; retryable waits', () async {
      await addFinished('dup');
      await addFinished('bad');
      await addFinished('later');
      api.results = {
        'dup': {'client_uuid': 'dup', 'status': 'duplicate'},
        'bad': {'client_uuid': 'bad', 'status': 'rejected', 'reason': 'foreign_enrollment'},
        'later': {'client_uuid': 'later', 'status': 'rejected', 'reason': 'server_error', 'retryable': true},
      };
      await sync().run();
      expect(await statusOf('dup'), RecordStatus.sent);
      expect((await store.record('bad'))!.errorReason, contains('not in this class'));
      expect((await store.record('later'))!.nextAttemptAt, now.add(const Duration(seconds: 30)));
    });

    test('batches hold at most 20 sessions', () async {
      for (var i = 0; i < 45; i++) {
        await addFinished('s$i');
      }
      await sync().run();
      expect(api.batches.map((b) => b.length), [20, 20, 5]);
    });

    test('network errors back off; 401 keeps everything queued', () async {
      await addFinished('a');
      api.failBatch = () => ApiException('offline', transient: true);
      expect((await sync().run()).error, 'offline');
      expect(await statusOf('a'), RecordStatus.finalized);

      api.failBatch = () => AuthExpiredException();
      now = now.add(const Duration(minutes: 1));
      expect((await sync().run()).authExpired, isTrue);
      expect(await statusOf('a'), RecordStatus.finalized);
    });

    test("only the current user's sessions are sent", () async {
      await addFinished('mine', owner: 1);
      await addFinished('theirs', owner: 2);
      await sync(userId: 1).run();
      expect(api.batches.single.map((s) => s['client_uuid']), ['mine']);
    });
  });

  group('setup made on the phone', () {
    Future<void> queueCourseAndClass() async {
      await queue('course-1', 'course', {'title': 'Baking', 'topics': [{'client_uuid': 'topic-1', 'position': 1, 'title': 'Safety', 'planned_sessions': 1, 'is_assessed': true}]});
      await queue('class-1', 'cohort', {'course_client_uuid': 'course-1', 'name': 'Baking - Epworth'});
      await queue('student-1', 'student', {'full_name': 'Rudo Banda'});
      await queue('enr-1', 'enrollment', {'cohort_client_uuid': 'class-1', 'student_client_uuid': 'student-1', '_roster_entry': {'client_uuid': 'enr-1', 'name': 'Rudo Banda'}});
    }

    test('setup is uploaded before sessions, grouped by kind, without device-only fields', () async {
      await queueCourseAndClass();
      await addFinished('a');
      await sync().run();

      expect(api.calls.take(2), ['setup', 'sessions']);
      final payload = api.setups.single;
      expect(payload.keys, ['courses', 'cohorts', 'students', 'enrollments']);
      expect(payload['enrollments']!.single.containsKey('_roster_entry'), isFalse);
      expect(await setupStatus('class-1'), SetupStatus.sent);
      expect(await statusOf('a'), RecordStatus.sent);
      expect(await store.cohortsAwaitingSetup(1), isEmpty);
    });

    test('sessions of a class wait while its setup has not been accepted', () async {
      await queueCourseAndClass();
      await addFinished('a');
      api.failSetup = () => ApiException('offline', transient: true);

      await sync().run();
      expect(api.batches, isEmpty);
      expect(await statusOf('a'), RecordStatus.finalized);
      expect(await setupStatus('class-1'), SetupStatus.pending);
    });

    test('a rejected setup item is marked failed with the reason and holds its class back', () async {
      await queueCourseAndClass();
      api.setupResults = {'class-1': {'kind': 'cohort', 'client_uuid': 'class-1', 'status': 'rejected', 'reason': 'not_owner'}};
      await addFinished('a');

      await sync().run();
      final item = (await store.setupItems()).firstWhere((i) => i.clientUuid == 'class-1');
      expect(item.status, SetupStatus.failed);
      expect(item.errorReason, contains('someone else'));
      expect(api.batches, isEmpty, reason: 'its sessions wait');
    });

    test('a course is only done when all its topics are accepted', () async {
      await queueCourseAndClass();
      api.setupResults = {'topic-1': {'kind': 'topic', 'client_uuid': 'topic-1', 'status': 'rejected', 'reason': 'client_uuid_conflict'}};
      await sync().run();
      expect(await setupStatus('course-1'), SetupStatus.failed);
    });

    test('student already in the class on the server: the phone adopts the server enrollment', () async {
      await store.saveCohort({'client_uuid': 'class-1', 'local': true, 'course': {'topics': []}, 'roster': [{'client_uuid': 'enr-1', 'name': 'Rudo'}]}, 1);
      await queue('enr-1', 'enrollment', {'cohort_client_uuid': 'class-1', 'beneficiary_id': 7});
      await addFinished('a', status: RecordStatus.draft);
      api.setupResults = {'enr-1': {'kind': 'enrollment', 'client_uuid': 'enr-1', 'status': 'duplicate', 'id': 5, 'server_client_uuid': 'server-enr'}};

      await sync().run();
      expect((await store.cohort('class-1'))!.roster.single.uuid, 'server-enr');
      expect((await store.record('a'))!.attendance.single['enrollment_client_uuid'], 'server-enr');
    });

    test('a download keeps students and topics added on the phone that are not uploaded yet', () async {
      await queue('course-1', 'course', {'title': 'Baking', 'topics': [{'client_uuid': 'topic-new', 'position': 2, 'title': 'Cakes'}]});
      await queue('enr-new', 'enrollment', {'cohort_client_uuid': 'class-1', 'beneficiary_id': 9, '_roster_entry': {'client_uuid': 'enr-new', 'name': 'New one'}});

      await store.saveDownloadedCohort({
        'id': 3, 'client_uuid': 'class-1', 'checksum': 'x',
        'course': {'topics': [{'client_uuid': 'topic-1', 'position': 1, 'title': 'Safety'}]},
        'roster': [{'client_uuid': 'enr-1', 'name': 'Rudo'}],
      }, 1);

      final c = (await store.cohort('class-1'))!;
      expect(c.topics.map((t) => t.uuid), ['topic-1', 'topic-new']);
      expect(c.roster.map((s) => s.uuid), ['enr-1', 'enr-new']);
    });

    test('a full download never drops a class still waiting to upload', () async {
      await store.saveCohort({'client_uuid': 'class-1', 'local': true, 'course': {'topics': []}, 'roster': []}, 1);
      await queue('class-1', 'cohort', {'course_client_uuid': 'course-1', 'name': 'Baking'});
      api.cohorts = [{'id': 5, 'client_uuid': 'other', 'name': 'Other', 'checksum': 'y'}];

      await sync().refreshCohorts();
      expect((await store.cohorts(1)).map((c) => c.uuid), containsAll(['class-1', 'other']));
    });
  });

  group('classes on listed courses', () {
    test('a class item carries its own topics; a rejected one fails the class', () async {
      await queue('class-1', 'cohort', {
        'course_client_uuid': 'tailoring-uuid', 'name': 'Tailoring - Mbare',
        'topics': [{'client_uuid': 'topic-1', 'position': 1, 'title': 'Measuring'}],
      });
      api.setupResults = {
        'class-1': {'kind': 'cohort', 'client_uuid': 'class-1', 'status': 'accepted', 'id': 3,
          'topics': [{'kind': 'topic', 'client_uuid': 'topic-1', 'status': 'rejected', 'reason': 'client_uuid_conflict'}]},
      };
      await sync().run();

      expect((api.setups.single['cohorts']!.single['topics'] as List).single['title'], 'Measuring');
      expect(await setupStatus('class-1'), SetupStatus.failed);
    });

    test('a download keeps class topics added on the phone that are not uploaded yet', () async {
      await queue('class-1', 'cohort', {'course_client_uuid': 'c', 'name': 'X', 'topics': [{'client_uuid': 'topic-new', 'position': 2, 'title': 'New'}]});
      await store.saveDownloadedCohort({'id': 3, 'client_uuid': 'class-1', 'checksum': 'x', 'course': {'topics': [{'client_uuid': 'topic-1', 'position': 1, 'title': 'Old'}]}, 'roster': []}, 1);

      expect((await store.cohort('class-1'))!.topics.map((t) => t.uuid), ['topic-1', 'topic-new']);
    });

    test('the waiting list leaves out youth already in the class', () {
      final c = LearningCohort({
        'client_uuid': 'k',
        'roster': [{'client_uuid': 'e1', 'beneficiary_id': 7}],
        'registered': [{'beneficiary_id': 7, 'name': 'In class'}, {'beneficiary_id': 8, 'name': 'Waiting'}],
      });
      expect(c.registered.map((r) => r['name']), ['Waiting']);
    });
  });

  test('changed-only refresh fetches changed classes and drops removed ones', () async {
    api.cohorts = [
      {'id': 5, 'client_uuid': 'a', 'name': 'A', 'checksum': 'x1'},
      {'id': 6, 'client_uuid': 'b', 'name': 'B', 'checksum': 'y1'},
    ];
    await sync().refreshCohorts();
    api.cohorts = [{'id': 5, 'client_uuid': 'a', 'name': 'A2', 'checksum': 'x2'}];
    api.status = (changed: [5], removed: [6]);

    await sync().refreshCohorts(changedOnly: true);
    expect(api.lastFetchIds, [5]);
    expect((await store.cohorts(1)).map((c) => c.name), ['A2']);
  });

  test('duration comes from start and end', () {
    final r = LocalSessionRecord(
      clientUuid: 'x', cohortUuid: 'c', heldOn: '2026-11-02', ownerUserId: 1, ownerName: '',
      startedAt: DateTime(2026, 11, 2, 9, 5), endedAt: DateTime(2026, 11, 2, 10, 55),
    );
    expect(r.duration, const Duration(minutes: 110));
  });
}
