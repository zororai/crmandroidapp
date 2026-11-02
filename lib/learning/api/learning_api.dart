import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/config.dart';

// Max session records per POST /learning/sessions/batch.
const learningBatchSize = 20;

// /api/v1/learning — same token, prefix, 401 and 429 handling as data collection.
abstract class LearningApi {
  // All cohorts the user facilitates, or only [ids].
  Future<List<Map<String, dynamic>>> fetchCohorts({List<int>? ids});

  Future<List<Map<String, dynamic>>> submitBatch(List<Map<String, dynamic>> sessions);

  // checksums: cohortId → checksum the device has. Returns changed cohort
  // ids and removed ones.
  Future<({List<int> changed, List<int> removed})> syncStatus(Map<int, String> checksums);

  Future<Map<String, dynamic>> performance();
}

LearningApi createLearningApi({required String? baseUrl, required String? token}) =>
    useMockDataCollectionApi ? MockLearningApi.instance : HttpLearningApi(baseUrl: baseUrl ?? '', token: token);

class HttpLearningApi implements LearningApi {
  HttpLearningApi({required this.baseUrl, required this.token, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final String? token;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl${dataCollectionApiPrefix}learning/$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request().timeout(const Duration(seconds: 45));
    } catch (_) {
      throw ApiException('Could not reach the server.', transient: true);
    }
    final code = res.statusCode;
    if (code == 401) throw AuthExpiredException();
    if (code < 200 || code >= 300) {
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
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchCohorts({List<int>? ids}) async {
    final body = await _send(() => _client.get(_uri('cohorts', ids == null ? null : {'ids': ids.join(',')}), headers: _headers));
    return ((body['cohorts'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  @override
  Future<List<Map<String, dynamic>>> submitBatch(List<Map<String, dynamic>> sessions) async {
    final body = await _send(() => _client.post(_uri('sessions/batch'), headers: _headers, body: jsonEncode({'sessions': sessions})));
    return ((body['results'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  @override
  Future<({List<int> changed, List<int> removed})> syncStatus(Map<int, String> checksums) async {
    final body = await _send(() => _client.get(
          _uri('sync-status', checksums.isEmpty ? null : {'checksums': checksums.entries.map((e) => '${e.key}:${e.value}').join(',')}),
          headers: _headers,
        ));
    return (
      changed: ((body['cohorts'] as List?) ?? const []).map((c) => (c as Map)['id'] as int).toList(),
      removed: ((body['removed'] as List?) ?? const []).cast<int>(),
    );
  }

  @override
  Future<Map<String, dynamic>> performance() => _send(() => _client.get(_uri('me/performance'), headers: _headers));
}

const demoCohortAsset = 'assets/learning/demo_cohort.json';

// Stand-in CRM for --dart-define=DC_MOCK_API=true: one demo cohort, and a
// server that accepts every session (repeats come back as duplicates).
class MockLearningApi implements LearningApi {
  MockLearningApi._();

  static final instance = MockLearningApi._();

  final _received = <String>{};

  Future<Map<String, dynamic>> _cohort() async => jsonDecode(await rootBundle.loadString(demoCohortAsset)) as Map<String, dynamic>;

  @override
  Future<List<Map<String, dynamic>>> fetchCohorts({List<int>? ids}) async => [await _cohort()];

  @override
  Future<List<Map<String, dynamic>>> submitBatch(List<Map<String, dynamic>> sessions) async => [
        for (final s in sessions) {'client_uuid': s['client_uuid'], 'status': _received.add(s['client_uuid'] as String) ? 'accepted' : 'duplicate'},
      ];

  @override
  Future<({List<int> changed, List<int> removed})> syncStatus(Map<int, String> checksums) async {
    final c = await _cohort();
    return (changed: checksums[c['id']] == c['checksum'] ? <int>[] : [c['id'] as int], removed: <int>[]);
  }

  @override
  Future<Map<String, dynamic>> performance() async => {
        'cohorts': 1, 'sessions_due': 5, 'sessions_held_on_time': 4, 'sessions_held_late': 1, 'sessions_missed': 0,
        'on_time_pct': 80.0, 'sessions_recorded': 5, 'late_syncs': 0, 'avg_duration_minutes': 112, 'attendance_rate_pct': 84.6,
      };
}
