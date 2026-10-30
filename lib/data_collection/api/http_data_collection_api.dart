import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/api_models.dart';
import 'data_collection_api.dart';

const _timeout = Duration(seconds: 30);
const _mediaTimeout = Duration(minutes: 2);

// The real CRM. Takes baseUrl and token explicitly (rather than reading
// ApiClient's statics) so the background isolate can build one from storage.
class HttpDataCollectionApi implements DataCollectionApi {
  HttpDataCollectionApi({required this.baseUrl, required this.token, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl; // e.g. http://192.168.10.149/api/
  final String? token;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$dataCollectionApiPrefix$path').replace(queryParameters: query);

  Map<String, String> _headers({bool json = false}) => {
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  // Network-level failures never reach a status code — always transient.
  Future<http.Response> _send(Future<http.Response> Function() request, {Duration timeout = _timeout}) async {
    final http.Response res;
    try {
      res = await request().timeout(timeout);
    } catch (e) {
      throw ApiException('Could not reach the server.', transient: true);
    }
    _check(res);
    return res;
  }

  void _check(http.Response res) {
    final code = res.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401) throw AuthExpiredException();

    String? message;
    try {
      message = (jsonDecode(res.body) as Map<String, dynamic>)['message']?.toString();
    } catch (_) {}
    final retryAfter = int.tryParse(res.headers['retry-after'] ?? '');
    throw ApiException(
      message ?? 'Server error ($code).',
      statusCode: code,
      transient: code == 408 || code == 429 || code >= 500,
      retryAfter: retryAfter == null ? null : Duration(seconds: retryAfter),
    );
  }

  // Lists may come bare or wrapped as {"data": [...]}.
  List<dynamic> _list(dynamic body, String key) {
    if (body is List) return body;
    if (body is Map && body[key] is List) return body[key] as List;
    if (body is Map && body['data'] is List) return body['data'] as List;
    return const [];
  }

  @override
  Future<List<RemoteForm>> fetchForms() async {
    final res = await _send(() => _client.get(_uri('forms'), headers: _headers()));
    return _list(jsonDecode(res.body), 'forms').whereType<Map<String, dynamic>>().map(RemoteForm.fromJson).toList();
  }

  @override
  Future<Map<String, dynamic>> fetchSchema(int formId, String version) async {
    final res = await _send(() => _client.get(_uri('forms/$formId/schema', {'version': version}), headers: _headers()));
    final body = jsonDecode(res.body);
    if (body is Map<String, dynamic>) {
      return body['schema'] is Map<String, dynamic> ? body['schema'] as Map<String, dynamic> : body;
    }
    throw ApiException('The form schema from the server is not valid.');
  }

  @override
  Future<List<BatchItemResult>> submitBatch(List<SubmissionPayload> submissions) async {
    final res = await _send(() => _client.post(
          _uri('submissions/batch'),
          headers: _headers(json: true),
          body: jsonEncode({'submissions': [for (final s in submissions) s.toJson()]}),
        ));
    return _list(jsonDecode(res.body), 'results').whereType<Map<String, dynamic>>().map(BatchItemResult.fromJson).toList();
  }

  @override
  Future<void> uploadMedia(String clientUuid, MediaReference media, Uint8List bytes) async {
    final request = http.MultipartRequest('POST', _uri('submissions/$clientUuid/media'))
      ..headers.addAll(_headers())
      ..fields['field'] = media.field
      ..fields['filename'] = media.fileName
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: media.fileName));
    try {
      await _send(() async => http.Response.fromStream(await _client.send(request)), timeout: _mediaTimeout);
    } on ApiException catch (e) {
      // Already stored by an earlier attempt.
      if (e.statusCode == 409) return;
      rethrow;
    }
  }

  @override
  Future<SyncStatusInfo> syncStatus() async {
    final res = await _send(() => _client.get(_uri('sync/status'), headers: _headers()));
    final body = jsonDecode(res.body);
    return SyncStatusInfo(
      forms: _list(body, 'forms').whereType<Map<String, dynamic>>().map(RemoteForm.fromJson).toList(),
      serverTime: body is Map ? DateTime.tryParse('${body['server_time']}') : null,
    );
  }
}
