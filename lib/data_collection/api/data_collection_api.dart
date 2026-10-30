import 'dart:typed_data';

import '../config.dart';
import '../models/api_models.dart';
import 'http_data_collection_api.dart';
import 'mock_data_collection_api.dart';

// The CRM contract (/api/v1, Bearer token from the existing login). An
// interface so the sync engine can be tested against a fake server.
abstract class DataCollectionApi {
  Future<List<RemoteForm>> fetchForms();

  Future<Map<String, dynamic>> fetchSchema(int formId, String version);

  // At most submissionBatchSize items; one result per item.
  Future<List<BatchItemResult>> submitBatch(List<SubmissionPayload> submissions);

  Future<void> uploadMedia(String clientUuid, MediaReference media, Uint8List bytes);

  Future<SyncStatusInfo> syncStatus();
}

DataCollectionApi createDataCollectionApi({required String? baseUrl, required String? token}) =>
    useMockDataCollectionApi ? MockDataCollectionApi.instance : HttpDataCollectionApi(baseUrl: baseUrl ?? '', token: token);

// `transient` failures (no network, timeouts, 5xx, 429) are retried with
// backoff; anything else is the server refusing the request.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.transient = false, this.retryAfter});

  final String message;
  final int? statusCode;
  final bool transient;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

// 401 — the token from login is no longer valid. Queued data is kept; the
// user is asked to log in again.
class AuthExpiredException implements Exception {
  @override
  String toString() => 'Your session has expired. Log in again to continue syncing.';
}
