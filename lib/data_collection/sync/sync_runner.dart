import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_client.dart';
import '../../db/database_helper.dart';
import '../../db/repository.dart';
import '../api/data_collection_api.dart';
import '../config.dart';
import '../db/data_collection_store.dart';
import '../models/api_models.dart';
import 'sync_engine.dart';

const _deviceIdKey = 'dc_device_id';

// A random id per install, sent with each submission so the CRM can tell
// devices apart. Not tied to hardware identifiers.
Future<String> deviceId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString(_deviceIdKey);
  if (id == null) {
    id = const Uuid().v4();
    await prefs.setString(_deviceIdKey, id);
  }
  return id;
}

// Everything a sync or form download needs, loaded from storage — never from
// in-memory app state — so the WorkManager isolate can build it on its own.
class DataCollectionContext {
  DataCollectionContext._(this.store, this.api, this.userId, this.userName);

  final DataCollectionStore store;
  final DataCollectionApi api;
  final int userId;
  final String userName;

  // Null when nobody is logged in.
  static Future<DataCollectionContext?> load() async {
    final db = await DatabaseHelper.instance.database;
    final repo = Repository();
    final user = await repo.getCurrentUser();
    if (user == null) return null;

    await ApiClient.loadBaseUrl();
    final api = createDataCollectionApi(baseUrl: ApiClient.baseUrl, token: await repo.readToken());
    return DataCollectionContext._(DataCollectionStore(db), api, user['userId'] as int, user['name'] as String? ?? '');
  }
}

class SyncRunner {
  static Future<SyncReport> run({bool force = false}) async {
    final ctx = await DataCollectionContext.load();
    if (ctx == null) return SyncReport.skipped('Not logged in.');
    if (ApiClient.baseUrl == null && !useMockDataCollectionApi) return SyncReport.skipped('No server address set.');

    final report = await SyncEngine(store: ctx.store, api: ctx.api, userId: ctx.userId, deviceId: await deviceId()).run(force: force);

    // Best effort: flag forms that have a newer version on the server.
    if (report.ok) {
      try {
        await ctx.store.markLatestVersions((await ctx.api.syncStatus()).forms);
      } catch (_) {}
    }
    return report;
  }

  // Pull-to-refresh on the forms list: update the listing, then download
  // every schema that's missing or older than the server's. Returns how
  // many schemas were downloaded.
  static Future<int> refreshForms() async {
    final ctx = await DataCollectionContext.load();
    if (ctx == null) throw AuthExpiredException();

    await ctx.store.saveFormListing(await ctx.api.fetchForms());
    var downloaded = 0;
    for (final RemoteForm form in await ctx.store.formsNeedingDownload()) {
      final schema = await ctx.api.fetchSchema(form.id, form.version);
      await ctx.store.saveSchema(form, jsonEncode(schema), DateTime.now());
      downloaded++;
    }
    return downloaded;
  }
}
