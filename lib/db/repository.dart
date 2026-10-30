import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../data_collection/api/data_collection_api.dart';
import '../data_collection/sync/sync_coordinator.dart';
import 'database_helper.dart';

const _uuid = Uuid();

// The API token lives in the platform keystore (Android Keystore-backed
// encryption), not in SQLite, where it would be readable from a rooted
// phone or a device backup. The session row keeps only who is logged in.
const _secureStorage = FlutterSecureStorage();
const _tokenKey = 'api_token';

class Repository {
  final _dbHelper = DatabaseHelper.instance;

  // ── Session: who is logged in (SQLite, offline-first like everything
  // else); the token itself is in secure storage ──

  Future<void> saveSessionFromLogin(Map<String, dynamic> loginResponse) async {
    final db = await _dbHelper.database;
    final user = loginResponse['user'] as Map<String, dynamic>;
    final token = loginResponse['token'] as String;

    // If secure storage is unavailable (e.g. Chrome on a plain-http address,
    // where the browser withholds WebCrypto) the token falls back to the
    // session row so login still works.
    final stored = await _writeSecureToken(token);
    await db.delete('session');
    await db.insert('session', {
      'id': 1,
      'userId': user['id'],
      'name': user['name'],
      'email': user['email'],
      'token': stored ? null : token,
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

  // The API token for the logged-in user. Everything that needs it reads it
  // through here (including the background sync isolate), so where it's
  // stored can change in one place.
  Future<String?> readToken() async {
    try {
      final token = await _secureStorage.read(key: _tokenKey);
      if (token != null) return token;
    } catch (_) {}
    return (await getCurrentUser())?['token'] as String?;
  }

  Future<bool> _writeSecureToken(String token) async {
    try {
      await _secureStorage.write(key: _tokenKey, value: token);
      return true;
    } catch (_) {
      return false;
    }
  }

  // One-off, on startup: builds before secure storage kept the token in the
  // session row. Move it across so those users stay logged in.
  Future<void> migrateTokenToSecureStorage() async {
    final token = (await getCurrentUser())?['token'] as String?;
    if (token == null || !await _writeSecureToken(token)) return;
    final db = await _dbHelper.database;
    await db.update('session', {'token': null}, where: 'id = 1');
  }

  Future<void> restoreTokenIntoMemory() async {
    ApiClient.setToken(await readToken());
  }

  Future<void> logout() async {
    final db = await _dbHelper.database;
    await db.delete('session');
    try {
      await _secureStorage.delete(key: _tokenKey);
    } catch (_) {}
    // Form assignments belong to the user who downloaded them. Their
    // unsent submissions stay, locked to that user (see LoginScreen).
    await db.delete('dc_forms');
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
      " + (SELECT COUNT(*) FROM dc_submissions WHERE status IN ('finalized', 'syncing')"
      ' AND ownerUserId = (SELECT userId FROM session WHERE id = 1)) as c',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // Pushes every not-yet-synced activity + its attendances in one batch.
  // Idempotent via client_uuid — safe to call repeatedly (e.g. a manual
  // "Sync Now" tap after a failed attempt).
  Future<void> syncPending() async {
    await _syncAttendances();
    await _syncProfiles();

    final report = await SyncCoordinator.instance.sync(force: true);
    if (report.authExpired) throw AuthExpiredException();
    if (report.error != null) throw Exception(report.error);
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
}
