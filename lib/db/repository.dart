import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import 'database_helper.dart';

const _uuid = Uuid();

class Repository {
  final _dbHelper = DatabaseHelper.instance;

  // ── Session (SQLite, not SharedPreferences — same reasoning as the
  // native app: keep it in the same offline-first store as everything else) ──

  Future<void> saveSessionFromLogin(Map<String, dynamic> loginResponse) async {
    final db = await _dbHelper.database;
    final user = loginResponse['user'] as Map<String, dynamic>;
    final token = loginResponse['token'] as String;

    await db.delete('session');
    await db.insert('session', {
      'id': 1,
      'userId': user['id'],
      'name': user['name'],
      'email': user['email'],
      'token': token,
      'loggedInAt': DateTime.now().toIso8601String(),
    });
    ApiClient.setToken(token);
  }

  Future<Map<String, dynamic>?> getCurrentUser() async {
    final db = await _dbHelper.database;
    final rows = await db.query('session', where: 'id = 1', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<bool> isLoggedIn() async => await getCurrentUser() != null;

  Future<void> restoreTokenIntoMemory() async {
    final user = await getCurrentUser();
    ApiClient.setToken(user?['token'] as String?);
  }

  Future<void> logout() async {
    final db = await _dbHelper.database;
    await db.delete('session');
    // Assignments belong to the user who downloaded them.
    await db.delete('forms');
    ApiClient.setToken(null);
  }

  // ── Activities (register header) ──

  Future<String> startActivity({
    required String activityName,
    required String activityDate,
    String? compiledBy,
    String? reviewedBy,
  }) async {
    final db = await _dbHelper.database;
    final uuid = _uuid.v4();
    await db.insert('activities', {
      'clientUuid': uuid,
      'activityName': activityName,
      'activityDate': activityDate,
      'compiledBy': compiledBy,
      'reviewedBy': reviewedBy,
      'synced': 0,
    });
    return uuid;
  }

  // ── Attendances (each beneficiary row) ──

  Future<void> captureAttendance({
    required String activityUuid,
    required String fullName,
    required String sex,
    int? age,
    String? district,
    String? phoneNumber,
    String? idNumberOrDob,
    Uint8List? signaturePng,
  }) async {
    final db = await _dbHelper.database;
    final clientUuid = _uuid.v4();

    final signaturePath = await _saveSignature(clientUuid, signaturePng);

    await db.insert('attendances', {
      'clientUuid': clientUuid,
      'activityUuid': activityUuid,
      'fullName': fullName,
      'sex': sex,
      'age': age,
      'district': district,
      'phoneNumber': phoneNumber,
      'idNumberOrDob': idNumberOrDob,
      'signaturePath': signaturePath,
      'capturedAt': DateTime.now().toIso8601String(),
      'synced': 0,
    });
  }

  // Signatures are PNG files on device. The browser can't write files, so on
  // web the PNG is kept inline in signaturePath as a data: URI instead.
  static const _inlinePrefix = 'data:image/png;base64,';

  Future<String?> _saveSignature(String clientUuid, Uint8List? png) async {
    if (png == null) return null;
    if (kIsWeb) return '$_inlinePrefix${base64Encode(png)}';
    final dir = await getApplicationDocumentsDirectory();
    final sigDir = Directory(p.join(dir.path, 'signatures'));
    await sigDir.create(recursive: true);
    final file = File(p.join(sigDir.path, '$clientUuid.png'));
    await file.writeAsBytes(png);
    return file.path;
  }

  Future<String?> _readSignatureBase64(String? path) async {
    if (path == null) return null;
    if (path.startsWith(_inlinePrefix)) return path.substring(_inlinePrefix.length);
    if (kIsWeb || !await File(path).exists()) return null;
    return base64Encode(await File(path).readAsBytes());
  }

  Future<List<Map<String, dynamic>>> findLocalByPhone(String phone) async {
    final db = await _dbHelper.database;
    return db.query('attendances', where: 'phoneNumber = ?', whereArgs: [phone], orderBy: 'capturedAt DESC');
  }

  // ── Profiles (Beneficiary Profiling Tool) ──

  // `answers` is already keyed the way BeneficiaryProfileController::sync
  // expects (full_name, phone_number, skill_interests, ...).
  Future<void> captureProfile({required Map<String, dynamic> answers, Uint8List? signaturePng}) async {
    final db = await _dbHelper.database;
    final clientUuid = _uuid.v4();
    final signaturePath = await _saveSignature(clientUuid, signaturePng);

    await db.insert('profiles', {
      'clientUuid': clientUuid,
      'fullName': answers['full_name'],
      'phoneNumber': answers['phone_number'],
      'data': jsonEncode(answers),
      'signaturePath': signaturePath,
      'capturedAt': DateTime.now().toIso8601String(),
      'synced': 0,
    });
  }

  Future<List<Map<String, dynamic>>> findLocalProfilesByPhone(String phone) async {
    final db = await _dbHelper.database;
    return db.query('profiles', where: 'phoneNumber = ?', whereArgs: [phone], orderBy: 'capturedAt DESC');
  }

  Future<int> pendingSyncCount() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery(
      'SELECT (SELECT COUNT(*) FROM attendances WHERE synced = 0) + (SELECT COUNT(*) FROM profiles WHERE synced = 0)'
      " + (SELECT COUNT(*) FROM submissions WHERE status = 'ready') as c",
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // Pushes every not-yet-synced activity + its attendances in one batch.
  // Idempotent via client_uuid — safe to call repeatedly (e.g. a manual
  // "Sync Now" tap after a failed attempt).
  Future<void> syncPending() async {
    await _syncAttendances();
    await _syncProfiles();
    await _syncSubmissions();
  }

  Future<void> _syncAttendances() async {
    final db = await _dbHelper.database;
    final unsyncedActivities = await db.query('activities', where: 'synced = 0');
    if (unsyncedActivities.isEmpty) return;

    final payload = <Map<String, dynamic>>[];
    for (final activity in unsyncedActivities) {
      final attendances = await db.query(
        'attendances',
        where: 'activityUuid = ? AND synced = 0',
        whereArgs: [activity['clientUuid']],
      );

      final attendancePayload = <Map<String, dynamic>>[];
      for (final a in attendances) {
        final signatureBase64 = await _readSignatureBase64(a['signaturePath'] as String?);

        attendancePayload.add({
          'client_uuid': a['clientUuid'],
          'full_name': a['fullName'],
          'sex': a['sex'],
          'age': a['age'],
          'district': a['district'],
          'phone_number': a['phoneNumber'],
          'id_number_or_dob': a['idNumberOrDob'],
          'captured_at': a['capturedAt'],
          'signature_base64': signatureBase64,
        });
      }

      payload.add({
        'client_uuid': activity['clientUuid'],
        'activity_name': activity['activityName'],
        'activity_date': activity['activityDate'],
        'compiled_by': activity['compiledBy'],
        'reviewed_by': activity['reviewedBy'],
        'attendances': attendancePayload,
      });
    }

    await ApiClient.sync(payload);

    // Mark everything just sent as synced.
    final batch = db.batch();
    for (final activity in unsyncedActivities) {
      batch.update('activities', {'synced': 1}, where: 'clientUuid = ?', whereArgs: [activity['clientUuid']]);
      batch.update('attendances', {'synced': 1}, where: 'activityUuid = ? AND synced = 0', whereArgs: [activity['clientUuid']]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> _syncProfiles() async {
    final db = await _dbHelper.database;
    final unsynced = await db.query('profiles', where: 'synced = 0');
    if (unsynced.isEmpty) return;

    final payload = <Map<String, dynamic>>[];
    for (final row in unsynced) {
      payload.add({
        ...jsonDecode(row['data'] as String) as Map<String, dynamic>,
        'client_uuid': row['clientUuid'],
        'captured_at': row['capturedAt'],
        'signature_base64': await _readSignatureBase64(row['signaturePath'] as String?),
      });
    }

    await ApiClient.syncProfiles(payload);

    final batch = db.batch();
    for (final row in unsynced) {
      batch.update('profiles', {'synced': 1}, where: 'clientUuid = ?', whereArgs: [row['clientUuid']]);
    }
    await batch.commit(noResult: true);
  }

  // ── Data collection (Kobo-style forms assigned in the CRM) ──

  // Replaces the local copy with what the server currently assigns. Drafts
  // and unsynced submissions are kept — they reference assignmentId only.
  Future<int> downloadForms() async {
    final assignments = await ApiClient.myForms();
    final db = await _dbHelper.database;
    final now = DateTime.now().toIso8601String();

    final batch = db.batch();
    batch.delete('forms');
    for (final a in assignments.cast<Map<String, dynamic>>()) {
      final schema = a['schema'];
      batch.insert('forms', {
        'assignmentId': a['assignment_id'],
        'formName': a['form_name'],
        'formDescription': a['form_description'],
        'projectName': a['project_name'],
        'versionLabel': a['version_label'],
        'schema': schema is String ? schema : jsonEncode(schema),
        'dueDate': a['due_date'],
        'downloadedAt': now,
      });
    }
    await batch.commit(noResult: true);
    return assignments.length;
  }

  Future<List<Map<String, dynamic>>> getForms() async {
    final db = await _dbHelper.database;
    return db.query('forms', orderBy: 'formName');
  }

  Future<List<Map<String, dynamic>>> getSubmissions(int assignmentId) async {
    final db = await _dbHelper.database;
    return db.query('submissions', where: 'assignmentId = ?', whereArgs: [assignmentId], orderBy: 'updatedAt DESC');
  }

  // Counts per status for one form, e.g. {'draft': 2, 'ready': 1}.
  Future<Map<String, int>> submissionCounts(int assignmentId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) as c FROM submissions WHERE assignmentId = ? GROUP BY status',
      [assignmentId],
    );
    return {for (final r in rows) r['status'] as String: r['c'] as int};
  }

  // Creates the submission when uid is null. finalize = true queues it for
  // sync; otherwise it stays an editable draft.
  Future<String> saveSubmission({
    String? uid,
    required int assignmentId,
    required String formName,
    required Map<String, dynamic> answers,
    required bool finalize,
  }) async {
    final db = await _dbHelper.database;
    final now = DateTime.now().toIso8601String();
    final row = {
      'answers': jsonEncode(answers),
      'status': finalize ? 'ready' : 'draft',
      'errorMessage': null,
      'updatedAt': now,
    };

    if (uid != null) {
      await db.update('submissions', row, where: 'submissionUid = ?', whereArgs: [uid]);
      return uid;
    }

    final newUid = _uuid.v4();
    await db.insert('submissions', {
      ...row,
      'submissionUid': newUid,
      'assignmentId': assignmentId,
      'formName': formName,
      'startedAt': now,
    });
    return newUid;
  }

  Future<void> deleteSubmission(String uid) async {
    final db = await _dbHelper.database;
    await db.delete('submissions', where: 'submissionUid = ?', whereArgs: [uid]);
  }

  Future<void> _syncSubmissions() async {
    final db = await _dbHelper.database;
    final ready = await db.query('submissions', where: "status = 'ready'");
    if (ready.isEmpty) return;

    final results = await ApiClient.syncSubmissions([
      for (final row in ready)
        {
          'submission_uid': row['submissionUid'],
          'assignment_id': row['assignmentId'],
          'answers': jsonDecode(row['answers'] as String),
          'started_at': row['startedAt'],
        },
    ]);

    // created/skipped both mean the server has it; failed goes back to the
    // user with the server's reason so it can be corrected.
    final batch = db.batch();
    for (final r in results.cast<Map<String, dynamic>>()) {
      final failed = r['status'] == 'failed';
      batch.update(
        'submissions',
        {'status': failed ? 'failed' : 'synced', 'errorMessage': failed ? r['message'] : null},
        where: 'submissionUid = ?',
        whereArgs: [r['submission_uid']],
      );
    }
    await batch.commit(noResult: true);
  }
}
