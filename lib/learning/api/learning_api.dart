import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/config.dart';

// Max session records per POST /learning/sessions/batch.
const learningBatchSize = 20;

// /api/v1/learning — same token, prefix, 401 and 429 handling as data collection.
abstract class LearningApi {
  // All classes the user facilitates, or only those with these server ids.
  Future<List<Map<String, dynamic>>> fetchCohorts({List<int>? ids});

  Future<List<Map<String, dynamic>>> submitBatch(List<Map<String, dynamic>> sessions);

  // checksums: server cohort id → checksum the device has. Returns changed
  // ids (including classes new to the device) and removed ones.
  Future<({List<int> changed, List<int> removed})> syncStatus(Map<int, String> checksums);

  Future<Map<String, dynamic>> performance();

  // POST /learning/setup — courses, cohorts, students, enrollments. One
  // result per item (and per topic).
  Future<List<Map<String, dynamic>>> setup(Map<String, List<Map<String, dynamic>>> payload);

  // Existing beneficiaries by name or phone (online only).
  Future<List<Map<String, dynamic>>> searchBeneficiaries(String query);
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
          _uri('sync-status', {'checksums': checksums.entries.map((e) => '${e.key}:${e.value}').join(',')}),
          headers: _headers,
        ));
    return (
      changed: ((body['cohorts'] as List?) ?? const []).map((c) => (c as Map)['id'] as int).toList(),
      removed: ((body['removed'] as List?) ?? const []).cast<int>(),
    );
  }

  @override
  Future<Map<String, dynamic>> performance() => _send(() => _client.get(_uri('me/performance'), headers: _headers));

  @override
  Future<List<Map<String, dynamic>>> setup(Map<String, List<Map<String, dynamic>>> payload) async {
    final body = await _send(() => _client.post(_uri('setup'), headers: _headers, body: jsonEncode(payload)));
    return ((body['results'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  @override
  Future<List<Map<String, dynamic>>> searchBeneficiaries(String query) async {
    final body = await _send(() => _client.get(_uri('beneficiaries', {'q': query}), headers: _headers));
    return ((body['results'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }
}

const demoCohortAsset = 'assets/learning/demo_cohort.json';

// Stand-in CRM for --dart-define=DC_MOCK_API=true: one demo class, plus any
// course/class the teacher sets up (kept in memory for this run), and a
// server that accepts every session.
class MockLearningApi implements LearningApi {
  MockLearningApi._();

  static final instance = MockLearningApi._();

  final _received = <String>{};
  final _created = <String, Map<String, dynamic>>{}; // cohort uuid → class JSON
  final _courses = <String, Map<String, dynamic>>{};
  final _students = <String, Map<String, dynamic>>{};
  var _nextId = 50000;

  static const _people = [
    {'id': 9101, 'client_uuid': 'aaaaaaaa-0000-4000-8000-000000009101', 'full_name': 'Tsitsi Mhlanga', 'gender': 'F', 'age': 18, 'location': 'Epworth', 'phone_number': '0772000101'},
    {'id': 9102, 'client_uuid': 'aaaaaaaa-0000-4000-8000-000000009102', 'full_name': 'Kudakwashe Zhou', 'gender': 'M', 'age': 20, 'location': 'Mbare', 'phone_number': '0772000102'},
    {'id': 9103, 'client_uuid': 'aaaaaaaa-0000-4000-8000-000000009103', 'full_name': 'Tariro Mutasa', 'gender': 'F', 'age': 17, 'location': 'Chitungwiza', 'phone_number': '0772000103'},
  ];

  Future<Map<String, dynamic>> _demo() async => jsonDecode(await rootBundle.loadString(demoCohortAsset)) as Map<String, dynamic>;

  @override
  Future<List<Map<String, dynamic>>> fetchCohorts({List<int>? ids}) async {
    final all = [await _demo(), ..._created.values];
    return ids == null ? all : all.where((c) => ids.contains(c['id'])).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> submitBatch(List<Map<String, dynamic>> sessions) async => [
        for (final s in sessions) {'client_uuid': s['client_uuid'], 'status': _received.add(s['client_uuid'] as String) ? 'accepted' : 'duplicate'},
      ];

  @override
  Future<({List<int> changed, List<int> removed})> syncStatus(Map<int, String> checksums) async {
    final changed = <int>[];
    for (final c in await fetchCohorts()) {
      if (checksums[c['id']] != c['checksum']) changed.add(c['id'] as int);
    }
    return (changed: changed, removed: <int>[]);
  }

  @override
  Future<Map<String, dynamic>> performance() async => {
        'cohorts': 1 + _created.length, 'sessions_due': 5, 'sessions_held_on_time': 4, 'sessions_held_late': 1, 'sessions_missed': 0,
        'on_time_pct': 80.0, 'sessions_recorded': 5, 'late_syncs': 0, 'avg_duration_minutes': 112, 'attendance_rate_pct': 84.6,
      };

  @override
  Future<List<Map<String, dynamic>>> searchBeneficiaries(String query) async {
    final q = query.toLowerCase();
    return _people.where((p) => '${p['full_name']}'.toLowerCase().contains(q) || '${p['phone_number']}'.contains(q)).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> setup(Map<String, List<Map<String, dynamic>>> payload) async {
    final results = <Map<String, dynamic>>[];
    for (final c in payload['courses'] ?? const <Map<String, dynamic>>[]) {
      _courses[c['client_uuid'] as String] = c;
      results.add({'kind': 'course', 'client_uuid': c['client_uuid'], 'status': 'accepted', 'id': _nextId++});
      for (final t in (c['topics'] as List).cast<Map<String, dynamic>>()) {
        t['id'] ??= _nextId++;
        results.add({'kind': 'topic', 'client_uuid': t['client_uuid'], 'status': 'accepted', 'id': t['id']});
      }
      for (final k in _created.values.where((k) => k['course']['client_uuid'] == c['client_uuid'])) {
        k['course'] = {...k['course'] as Map, 'title': c['title'], 'topics': c['topics']};
        k['checksum'] = 'mock-${_nextId++}';
      }
    }
    for (final k in payload['cohorts'] ?? const <Map<String, dynamic>>[]) {
      final course = _courses[k['course_client_uuid']] ?? {'client_uuid': k['course_client_uuid'], 'title': '', 'topics': []};
      _created[k['client_uuid'] as String] = {
        'id': _nextId++, 'client_uuid': k['client_uuid'], 'name': k['name'], 'venue': k['venue'], 'status': 'running',
        'start_date': k['start_date'], 'end_date': k['end_date'], 'my_role': 'lead', 'checksum': 'mock-${_nextId++}',
        'course': {'client_uuid': course['client_uuid'], 'title': course['title'], 'description': course['description'], 'can_edit': true, 'min_attendance_pct': 75, 'topics': course['topics']},
        'roster': <dynamic>[], 'sessions': <dynamic>[], 'records': <dynamic>[], 'topic_progress': <dynamic>[], 'progress': <String, dynamic>{},
      };
      results.add({'kind': 'cohort', 'client_uuid': k['client_uuid'], 'status': 'accepted', 'id': _created[k['client_uuid']]!['id']});
    }
    for (final s in payload['students'] ?? const <Map<String, dynamic>>[]) {
      _students[s['client_uuid'] as String] = s;
      results.add({'kind': 'student', 'client_uuid': s['client_uuid'], 'status': 'accepted', 'id': _nextId++});
    }
    for (final e in payload['enrollments'] ?? const <Map<String, dynamic>>[]) {
      final k = _created[e['cohort_client_uuid']];
      final person = e['student_client_uuid'] != null
          ? _students[e['student_client_uuid']]
          : _people.where((p) => p['id'] == e['beneficiary_id']).firstOrNull;
      if (k != null && person != null) {
        (k['roster'] as List).add({
          'enrollment_id': _nextId++, 'client_uuid': e['client_uuid'], 'name': person['full_name'], 'gender': person['gender'],
          'age': person['age'], 'phone_number': person['phone_number'], 'location': person['location'], 'student_ref': e['student_ref'],
          'status': 'active', 'enrolled_at': e['enrolled_at'], 'attendance_pct': null, 'at_risk': <dynamic>[],
        });
        k['checksum'] = 'mock-${_nextId++}';
      }
      results.add({'kind': 'enrollment', 'client_uuid': e['client_uuid'], 'status': k != null ? 'accepted' : 'rejected', if (k == null) 'reason': 'unknown_cohort'});
    }
    return results;
  }
}
