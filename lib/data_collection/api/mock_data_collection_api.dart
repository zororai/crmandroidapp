import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';

import '../models/api_models.dart';
import 'data_collection_api.dart';

const sampleFormAsset = 'assets/data_collection/household_survey.json';

// Stand-in CRM for running the app before the Laravel endpoints exist
// (--dart-define=DC_MOCK_API=true). Serves the bundled household survey and
// accepts everything, reporting repeats as duplicates like the real server.
class MockDataCollectionApi implements DataCollectionApi {
  MockDataCollectionApi._();

  static final instance = MockDataCollectionApi._();

  final _received = <String>{};

  Future<Map<String, dynamic>> _sample() async => jsonDecode(await rootBundle.loadString(sampleFormAsset)) as Map<String, dynamic>;

  Future<RemoteForm> _sampleListing() async {
    final schema = await _sample();
    return RemoteForm(
      id: schema['form_id'] as int,
      title: schema['title'] as String,
      version: '${schema['version']}',
      checksum: 'sample-${schema['version']}',
      updatedAt: DateTime(2026, 10, 1),
    );
  }

  @override
  Future<List<RemoteForm>> fetchForms() async => [await _sampleListing()];

  @override
  Future<Map<String, dynamic>> fetchSchema(int formId, String version) => _sample();

  @override
  Future<List<BatchItemResult>> submitBatch(List<SubmissionPayload> submissions) async => [
        for (final s in submissions)
          BatchItemResult(
            clientUuid: s.clientUuid,
            status: _received.add(s.clientUuid) ? BatchItemStatus.accepted : BatchItemStatus.duplicate,
          ),
      ];

  @override
  Future<void> uploadMedia(String clientUuid, MediaReference media, Uint8List bytes) async {}

  @override
  Future<SyncStatusInfo> syncStatus() async => SyncStatusInfo(forms: [await _sampleListing()], serverTime: DateTime.now());
}
