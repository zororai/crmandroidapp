import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// Same three tables as the native Kotlin/Room version: session (one row,
// who's logged in), activities (the register header), attendances (each
// beneficiary row) — plus profiles (the Beneficiary Profiling Tool form)
// and the data collection tables (dc_*, see createDataCollectionTables).
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
      version: 4,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createProfilesTable(db);
        if (oldVersion < 4) {
          // v3 had a first, simpler data collection feature (forms +
          // submissions). It was pushed but never released, so its tables
          // are set aside rather than dropped, in case a test device holds
          // something worth recovering.
          if (oldVersion == 3) {
            await db.execute('ALTER TABLE forms RENAME TO legacy_v3_forms');
            await db.execute('ALTER TABLE submissions RENAME TO legacy_v3_submissions');
          }
          await createDataCollectionTables(db);
        }
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
        await createDataCollectionTables(db);
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

// Data collection (KoboToolbox-style forms from the CRM). Public so tests can
// build the same tables in an in-memory database.
//  dc_forms         assigned forms: the latest version the server reported,
//                   and the version cached on the device (update badge when
//                   they differ)
//  dc_form_schemas  every downloaded schema version, so a draft started on
//                   an older version still opens after the form is updated
//  dc_submissions   one row per filled-in form; also the sync queue (status,
//                   attempts, nextAttemptAt drive retries)
//  dc_media         photos, uploaded only after their submission's data
//  dc_sync_runs     history for the sync status screen
Future<void> createDataCollectionTables(Database db) async {
  await db.execute('''
    CREATE TABLE dc_forms (
      formId INTEGER PRIMARY KEY,
      title TEXT,
      latestVersion TEXT,
      latestChecksum TEXT,
      updatedAt TEXT,
      cachedVersion TEXT,
      cachedChecksum TEXT
    )
  ''');

  await db.execute('''
    CREATE TABLE dc_form_schemas (
      formId INTEGER,
      version TEXT,
      checksum TEXT,
      schemaJson TEXT,
      downloadedAt TEXT,
      PRIMARY KEY (formId, version)
    )
  ''');

  await db.execute('''
    CREATE TABLE dc_submissions (
      clientUuid TEXT PRIMARY KEY,
      formId INTEGER,
      formVersion TEXT,
      formTitle TEXT,
      ownerUserId INTEGER,
      ownerName TEXT,
      status TEXT,
      data TEXT,
      payload TEXT,
      lat REAL,
      lng REAL,
      startedAt TEXT,
      updatedAt TEXT,
      finalizedAt TEXT,
      sentAt TEXT,
      dataAccepted INTEGER DEFAULT 0,
      attempts INTEGER DEFAULT 0,
      nextAttemptAt TEXT,
      errorReason TEXT
    )
  ''');
  await db.execute('CREATE INDEX dc_submissions_owner_status ON dc_submissions (ownerUserId, status)');

  await db.execute('''
    CREATE TABLE dc_media (
      fileName TEXT PRIMARY KEY,
      clientUuid TEXT,
      fieldName TEXT,
      path TEXT,
      mimeType TEXT,
      sizeBytes INTEGER,
      uploaded INTEGER DEFAULT 0
    )
  ''');

  await db.execute('''
    CREATE TABLE dc_sync_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      startedAt TEXT,
      finishedAt TEXT,
      sent INTEGER,
      failed INTEGER,
      pending INTEGER,
      error TEXT
    )
  ''');
}
