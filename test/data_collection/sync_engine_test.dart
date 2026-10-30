import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/api/data_collection_api.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/db/data_collection_store.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/media/media_files.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/models/api_models.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/models/submission.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/sync/sync_engine.dart';
import 'package:yazcrm_beneficiary_flutter/db/database_helper.dart';

// Scriptable stand-in for the CRM. `onBatch` / `onMedia` decide each call's
// outcome; every call is recorded so tests can assert on order and size.
class FakeCrmApi implements DataCollectionApi {
  final batches = <List<String>>[];
  final mediaUploads = <String>[]; // "uuid/filename"
  final calls = <String>[]; // 'batch' / 'media' in call order

  final _stored = <String>{};
  Object? Function(List<SubmissionPayload> batch)? failBatch; // return an exception to throw
  Object? Function(String fileName)? failMedia;
  Map<String, String> reject = {}; // uuid → reason

  @override
  Future<List<BatchItemResult>> submitBatch(List<SubmissionPayload> submissions) async {
    calls.add('batch');
    batches.add([for (final s in submissions) s.clientUuid]);
    final error = failBatch?.call(submissions);
    if (error != null) throw error;
    return [
      for (final s in submissions)
        if (reject.containsKey(s.clientUuid))
          BatchItemResult(clientUuid: s.clientUuid, status: BatchItemStatus.rejected, reason: reject[s.clientUuid])
        else
          BatchItemResult(clientUuid: s.clientUuid, status: _stored.add(s.clientUuid) ? BatchItemStatus.accepted : BatchItemStatus.duplicate),
    ];
  }

  @override
  Future<void> uploadMedia(String clientUuid, MediaReference media, Uint8List bytes) async {
    calls.add('media');
    final error = failMedia?.call(media.fileName);
    if (error != null) throw error;
    if (!_stored.contains(clientUuid)) throw StateError('media uploaded before its data');
    mediaUploads.add('$clientUuid/${media.fileName}');
  }

  void markStored(String uuid) => _stored.add(uuid);

  @override
  Future<List<RemoteForm>> fetchForms() async => const [];

  @override
  Future<Map<String, dynamic>> fetchSchema(int formId, String version) async => const {};

  @override
  Future<SyncStatusInfo> syncStatus() async => const SyncStatusInfo(forms: []);
}

class FakeMediaFiles extends MediaFiles {
  final files = <String, Uint8List>{};
  final deleted = <String>[];

  @override
  Future<Uint8List?> read(String path) async => files[path];

  @override
  Future<void> delete(String path) async => deleted.add(path);
}

void main() {
  sqfliteFfiInit();

  late Database db;
  late DataCollectionStore store;
  late FakeCrmApi api;
  late FakeMediaFiles files;
  var now = DateTime(2026, 10, 30, 9);

  SyncEngine engine({int userId = 1}) =>
      SyncEngine(store: store, api: api, userId: userId, deviceId: 'device-1', mediaFiles: files, now: () => now);

  Future<String> addFinalized(String uuid, {int owner = 1, List<String> photos = const []}) async {
    await store.insertSubmission(Submission(
      clientUuid: uuid,
      formId: 9001,
      formVersion: '1',
      formTitle: 'Survey',
      ownerUserId: owner,
      ownerName: 'User $owner',
      status: SubmissionStatus.finalized,
      data: {'q': uuid},
      payload: {'q': uuid},
      startedAt: now,
      updatedAt: now,
      finalizedAt: now,
    ));
    for (final name in photos) {
      final path = '/media/$name';
      files.files[path] = Uint8List.fromList([1, 2, 3]);
      await store.insertMedia(MediaRecord(fileName: name, clientUuid: uuid, fieldName: 'photo', path: path, mimeType: 'image/jpeg', sizeBytes: 3));
    }
    return uuid;
  }

  Future<SubmissionStatus> statusOf(String uuid) async => (await store.submission(uuid))!.status;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: (db, _) => createDataCollectionTables(db)),
    );
    store = DataCollectionStore(db);
    api = FakeCrmApi();
    files = FakeMediaFiles();
    now = DateTime(2026, 10, 30, 9);
  });

  tearDown(() => db.close());

  test('accepted submissions become sent', () async {
    await addFinalized('a');
    final report = await engine().run();
    expect(report.sent, 1);
    expect(await statusOf('a'), SubmissionStatus.sent);
  });

  test('payload carries the contract fields', () async {
    await addFinalized('a');
    SubmissionPayload? seen;
    api.failBatch = (batch) {
      seen = batch.single;
      return null;
    };
    await engine().run();
    final json = seen!.toJson();
    expect(json.keys, containsAll(['client_uuid', 'form_id', 'form_version', 'collected_at', 'device_id', 'app_version', 'lat', 'lng', 'data', 'media']));
    expect(json['device_id'], 'device-1');
  });

  test('duplicate is treated as success', () async {
    await addFinalized('a');
    api.markStored('a'); // an earlier attempt already got through
    await engine().run();
    expect(await statusOf('a'), SubmissionStatus.sent);
  });

  test('partial batch failure: rejected items fail with the reason, others go through', () async {
    await addFinalized('a');
    await addFinalized('b');
    await addFinalized('c');
    api.reject = {'b': 'Age must be between 0 and 120.'};
    final report = await engine().run();

    expect(report.sent, 2);
    expect(report.failed, 1);
    expect(await statusOf('a'), SubmissionStatus.sent);
    expect(await statusOf('c'), SubmissionStatus.sent);
    final b = (await store.submission('b'))!;
    expect(b.status, SubmissionStatus.failed);
    expect(b.errorReason, 'Age must be between 0 and 120.');
  });

  test('rejected submissions are not retried automatically', () async {
    await addFinalized('a');
    api.reject = {'a': 'Bad'};
    await engine().run();
    await engine().run();
    expect(api.batches.length, 1);
  });

  test('batches hold at most 50 submissions', () async {
    for (var i = 0; i < 120; i++) {
      await addFinalized('s${i.toString().padLeft(3, '0')}');
    }
    await engine().run();
    expect(api.batches.map((b) => b.length), [50, 50, 20]);
  });

  group('transient errors and backoff', () {
    test('5xx keeps data queued with exponential backoff', () async {
      await addFinalized('a');
      api.failBatch = (_) => ApiException('Server error (503).', statusCode: 503, transient: true);
      final report = await engine().run();

      expect(report.error, isNotNull);
      final a = (await store.submission('a'))!;
      expect(a.status, SubmissionStatus.finalized);
      expect(a.attempts, 1);
      expect(a.nextAttemptAt, now.add(const Duration(seconds: 30)));
    });

    test('not retried before the backoff expires, retried after', () async {
      await addFinalized('a');
      api.failBatch = (_) => ApiException('offline', transient: true);
      await engine().run();
      api.failBatch = null;

      now = now.add(const Duration(seconds: 10));
      await engine().run();
      expect(api.batches.length, 1, reason: 'still backing off');

      now = now.add(const Duration(seconds: 30));
      await engine().run();
      expect(await statusOf('a'), SubmissionStatus.sent);
    });

    test('a manual sync ignores the backoff', () async {
      await addFinalized('a');
      api.failBatch = (_) => ApiException('offline', transient: true);
      await engine().run();
      api.failBatch = null;
      await engine().run(force: true);
      expect(await statusOf('a'), SubmissionStatus.sent);
    });

    test('delay doubles and is capped; Retry-After wins when longer', () {
      expect(retryDelay(1), const Duration(seconds: 30));
      expect(retryDelay(2), const Duration(minutes: 1));
      expect(retryDelay(4), const Duration(minutes: 4));
      expect(retryDelay(20), const Duration(hours: 1));
      expect(retryDelay(1, retryAfter: const Duration(minutes: 5)), const Duration(minutes: 5));
    });

    test('a non-transient error on the whole batch marks it failed', () async {
      await addFinalized('a');
      api.failBatch = (_) => ApiException('The submissions field is required.', statusCode: 422);
      await engine().run();
      expect(await statusOf('a'), SubmissionStatus.failed);
    });
  });

  group('token expiry', () {
    test('401 stops the run and leaves the queue intact', () async {
      await addFinalized('a');
      await addFinalized('b');
      api.failBatch = (_) => AuthExpiredException();
      final report = await engine().run();

      expect(report.authExpired, isTrue);
      expect(await statusOf('a'), SubmissionStatus.finalized);
      expect(await statusOf('b'), SubmissionStatus.finalized);
      expect((await store.submission('a'))!.attempts, 0, reason: 'not counted as a failed attempt');
    });

    test('after logging in again the same queue is sent', () async {
      await addFinalized('a');
      api.failBatch = (_) => AuthExpiredException();
      await engine().run();
      api.failBatch = null;
      await engine().run();
      expect(await statusOf('a'), SubmissionStatus.sent);
    });
  });

  group('media after data', () {
    test('photos upload only after the data is accepted', () async {
      await addFinalized('a', photos: ['p1.jpg', 'p2.jpg']);
      await engine().run();
      expect(api.calls, ['batch', 'media', 'media']);
      expect(api.mediaUploads, ['a/p1.jpg', 'a/p2.jpg']);
      expect(await statusOf('a'), SubmissionStatus.sent);
    });

    test('no photos are uploaded when the data is rejected', () async {
      await addFinalized('a', photos: ['p1.jpg']);
      api.reject = {'a': 'Bad'};
      await engine().run();
      expect(api.mediaUploads, isEmpty);
    });

    test('a failed photo upload keeps the data accepted and does not resend it', () async {
      await addFinalized('a', photos: ['p1.jpg', 'p2.jpg']);
      api.failMedia = (name) => name == 'p2.jpg' ? ApiException('timeout', transient: true) : null;
      await engine().run();

      final a = (await store.submission('a'))!;
      expect(a.status, SubmissionStatus.finalized);
      expect(a.dataAccepted, isTrue);

      api.failMedia = null;
      now = now.add(const Duration(minutes: 1));
      await engine().run();
      expect(api.batches.length, 1, reason: 'data is not sent twice');
      expect(api.mediaUploads, ['a/p1.jpg', 'a/p2.jpg'], reason: 'p1 is not uploaded twice');
      expect(await statusOf('a'), SubmissionStatus.sent);
    });

    test('a photo missing from the device fails the submission with a reason', () async {
      await addFinalized('a', photos: ['p1.jpg']);
      files.files.clear();
      await engine().run();
      final a = (await store.submission('a'))!;
      expect(a.status, SubmissionStatus.failed);
      expect(a.errorReason, contains('missing'));
    });
  });

  test("only the current user's submissions are synced", () async {
    await addFinalized('mine', owner: 1);
    await addFinalized('theirs', owner: 2);
    await engine(userId: 1).run();
    expect(api.batches.expand((b) => b), ['mine']);
    expect(await statusOf('theirs'), SubmissionStatus.finalized);
  });

  test('sent submissions and their photos are purged after the retention period', () async {
    await addFinalized('a', photos: ['p1.jpg']);
    await engine().run();
    expect(await store.submission('a'), isNotNull, reason: 'kept as sent history');

    now = now.add(const Duration(days: 31));
    await engine().run();
    expect(await store.submission('a'), isNull);
    expect(files.deleted, ['/media/p1.jpg']);
  });

  test('every run is recorded for the sync status screen', () async {
    await addFinalized('a');
    await engine().run();
    final runs = await store.recentRuns();
    expect(runs.single['sent'], 1);
    expect(runs.single['pending'], 0);
  });
}
