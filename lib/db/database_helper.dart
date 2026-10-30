import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// Same three tables as the native Kotlin/Room version: session (one row,
// who's logged in), activities (the register header), attendances (each
// beneficiary row) — plus profiles (the Beneficiary Profiling Tool form).
// Everything written here works fully offline — sync is a separate,
// explicit step against the Laravel API.
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  static Database? _db;

  DatabaseHelper._internal();

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    // The browser has no documents folder — on web the name is just the
    // IndexedDB key.
    final path = kIsWeb ? 'beneficiary.db' : join((await getApplicationDocumentsDirectory()).path, 'beneficiary.db');

    return openDatabase(
      path,
      version: 2,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createProfilesTable(db);
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE session (
            id INTEGER PRIMARY KEY,
            userId INTEGER,
            name TEXT,
            email TEXT,
            token TEXT,
            loggedInAt TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE activities (
            clientUuid TEXT PRIMARY KEY,
            activityName TEXT,
            activityDate TEXT,
            compiledBy TEXT,
            reviewedBy TEXT,
            synced INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE attendances (
            clientUuid TEXT PRIMARY KEY,
            activityUuid TEXT,
            fullName TEXT,
            sex TEXT,
            age INTEGER,
            district TEXT,
            phoneNumber TEXT,
            idNumberOrDob TEXT,
            signaturePath TEXT,
            capturedAt TEXT,
            synced INTEGER DEFAULT 0
          )
        ''');

        await _createProfilesTable(db);
      },
    );
  }

  // The profiling form has ~40 answers that only matter to the server, so
  // they live as one JSON blob (already in the sync payload's snake_case
  // shape); only the columns needed for lookup are broken out.
  Future<void> _createProfilesTable(Database db) async {
    await db.execute('''
      CREATE TABLE profiles (
        clientUuid TEXT PRIMARY KEY,
        fullName TEXT,
        phoneNumber TEXT,
        data TEXT,
        signaturePath TEXT,
        capturedAt TEXT,
        synced INTEGER DEFAULT 0
      )
    ''');
  }
}
