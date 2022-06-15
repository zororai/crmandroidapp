import 'dart:async';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// Same three tables as the native Kotlin/Room version: session (one row,
// who's logged in), activities (the register header), attendances (each
// beneficiary row). Everything written here works fully offline — sync
// is a separate, explicit step against the Laravel API.
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  static Database? _db;

  DatabaseHelper._internal();

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'beneficiary.db');

    return openDatabase(
      path,
      version: 1,
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
      },
    );
  }
}
