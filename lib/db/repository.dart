import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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

    String? signaturePath;
    if (signaturePng != null) {
      final dir = await getApplicationDocumentsDirectory();
      final sigDir = Directory(p.join(dir.path, 'signatures'));
      await sigDir.create(recursive: true);
      final file = File(p.join(sigDir.path, '$clientUuid.png'));
      await file.writeAsBytes(signaturePng);
      signaturePath = file.path;
    }

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

  Future<List<Map<String, dynamic>>> findLocalByPhone(String phone) async {
    final db = await _dbHelper.database;
    return db.query('attendances', where: 'phoneNumber = ?', whereArgs: [phone], orderBy: 'capturedAt DESC');
  }

  Future<int> pendingSyncCount() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery('SELECT COUNT(*) as c FROM attendances WHERE synced = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // Pushes every not-yet-synced activity + its attendances in one batch.
  // Idempotent via client_uuid — safe to call repeatedly (e.g. a manual
  // "Sync Now" tap after a failed attempt).
  Future<void> syncPending() async {
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
        String? signatureBase64;
        final path = a['signaturePath'] as String?;
        if (path != null && await File(path).exists()) {
          signatureBase64 = base64Encode(await File(path).readAsBytes());
        }

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
}
