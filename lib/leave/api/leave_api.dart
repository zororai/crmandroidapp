import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../../api/api_client.dart';
import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/config.dart';
import '../../db/repository.dart';
import '../models/leave_models.dart';

// /api/v1/leave — online only; leave needs the server's balances and rules.
// Same token, prefix and error handling as the other app modules:
//  401 → AuthExpiredException (expired login, or the account was disabled)
//  403 → ApiException(statusCode: 403) carrying the server's reason
//  422 → ApiException with the first validation message
abstract class LeaveApi {
  Future<List<LeaveType>> types();
  Future<({int year, List<LeaveBalance> balances})> balances({int? year});
  Future<List<LeaveRequest>> myRequests({LeaveStatus? status});
  Future<LeaveRequest> request(int id);
  Future<LeaveRequest> apply(LeaveApplication application);
  Future<LeaveRequest> cancel(int id);
  Future<List<LeaveRequest>> pending();
  Future<LeaveRequest> approve(int id, {String? comment});
  Future<LeaveRequest> reject(int id, String comment);
  Future<TeamCalendar> calendar(DateTime from, DateTime to);
  Future<int> workingDays(DateTime start, DateTime end);
}

// Built per screen from the saved server address and token.
Future<LeaveApi> createLeaveApi() async {
  if (useMockDataCollectionApi) return MockLeaveApi.instance;
  return HttpLeaveApi(baseUrl: ApiClient.baseUrl ?? '', token: await Repository().readToken());
}

final _day = DateFormat('yyyy-MM-dd');

class HttpLeaveApi implements LeaveApi {
  HttpLeaveApi({required this.baseUrl, required this.token, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final String? token;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl${dataCollectionApiPrefix}leave/$path');
    return query == null || query.isEmpty ? uri : uri.replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request().timeout(const Duration(seconds: 30));
    } catch (_) {
      throw ApiException('Could not reach the server. Check your connection and pull down to try again.', transient: true);
    }
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    final code = res.statusCode;
    if (code == 401) throw AuthExpiredException();

    Map<String, dynamic> body = const {};
    try {
      body = (jsonDecode(res.body) as Map).cast<String, dynamic>();
    } catch (_) {}

    if (code < 200 || code >= 300) {
      // A 422's first field error is the most useful sentence to show.
      final errors = body['errors'];
      String? message;
      if (errors is Map && errors.isNotEmpty) {
        final first = errors.values.first;
        message = first is List && first.isNotEmpty ? first.first.toString() : first.toString();
      }
      message ??= body['message']?.toString();
      throw ApiException(
        message ?? 'Server error ($code).',
        statusCode: code,
        transient: code == 408 || code == 429 || code >= 500,
      );
    }
    return body;
  }

  List<Map<String, dynamic>> _list(Object? v) => ((v as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();

  @override
  Future<List<LeaveType>> types() async {
    final body = await _send(() => _client.get(_uri('types'), headers: _headers));
    return _list(body['data']).map(LeaveType.fromJson).toList();
  }

  @override
  Future<({int year, List<LeaveBalance> balances})> balances({int? year}) async {
    final body = await _send(() => _client.get(_uri('balances', {if (year != null) 'year': '$year'}), headers: _headers));
    return (year: body['year'] as int, balances: _list(body['balances']).map(LeaveBalance.fromJson).toList());
  }

  @override
  Future<List<LeaveRequest>> myRequests({LeaveStatus? status}) async {
    final body = await _send(() => _client.get(_uri('requests', {if (status != null) 'status': status.name}), headers: _headers));
    return _list(body['data']).map(LeaveRequest.fromJson).toList();
  }

  @override
  Future<LeaveRequest> request(int id) async {
    final body = await _send(() => _client.get(_uri('requests/$id'), headers: _headers));
    return LeaveRequest.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  @override
  Future<LeaveRequest> apply(LeaveApplication a) async {
    final fields = {
      'leave_type_id': '${a.typeId}',
      'start_date': _day.format(a.start),
      'end_date': _day.format(a.end),
      if (a.reason != null && a.reason!.trim().isNotEmpty) 'reason': a.reason!.trim(),
    };

    final Map<String, dynamic> body;
    if (a.attachmentBytes == null) {
      body = await _send(() => _client.post(_uri('requests'), headers: _headers, body: jsonEncode(fields)));
    } else {
      // Multipart for the attachment; no JSON content type on this one.
      final multipart = http.MultipartRequest('POST', _uri('requests'))
        ..headers.addAll({'Accept': 'application/json', if (token != null) 'Authorization': 'Bearer $token'})
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile.fromBytes('attachment', a.attachmentBytes!, filename: a.attachmentName ?? 'attachment.jpg'));
      body = await _send(() async => http.Response.fromStream(await _client.send(multipart)));
    }
    return LeaveRequest.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  @override
  Future<LeaveRequest> cancel(int id) => _patch('requests/$id/cancel');

  @override
  Future<List<LeaveRequest>> pending() async {
    final body = await _send(() => _client.get(_uri('pending'), headers: _headers));
    return _list(body['data']).map(LeaveRequest.fromJson).toList();
  }

  @override
  Future<LeaveRequest> approve(int id, {String? comment}) =>
      _patch('requests/$id/approve', {if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim()});

  @override
  Future<LeaveRequest> reject(int id, String comment) => _patch('requests/$id/reject', {'comment': comment.trim()});

  Future<LeaveRequest> _patch(String path, [Map<String, dynamic>? data]) async {
    final body = await _send(() => _client.patch(_uri(path), headers: _headers, body: jsonEncode(data ?? const {})));
    return LeaveRequest.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  @override
  Future<TeamCalendar> calendar(DateTime from, DateTime to) async {
    final body = await _send(() => _client.get(_uri('calendar', {'from': _day.format(from), 'to': _day.format(to)}), headers: _headers));
    return TeamCalendar(
      from: from,
      to: to,
      requests: _list(body['requests']).map(LeaveRequest.fromJson).toList(),
      holidays: _list(body['holidays']).map(PublicHoliday.fromJson).toList(),
    );
  }

  @override
  Future<int> workingDays(DateTime start, DateTime end) async {
    final body = await _send(() => _client.get(_uri('working-days', {'start_date': _day.format(start), 'end_date': _day.format(end)}), headers: _headers));
    return body['days'] as int;
  }
}

// `--dart-define=DC_MOCK_API=true`: an in-memory stand-in so the screens can
// be tried without a CRM. One user who is also an approver of "Tariro".
class MockLeaveApi implements LeaveApi {
  MockLeaveApi._();
  static final instance = MockLeaveApi._();

  static const _annual = LeaveType(id: 1, name: 'Annual', isPaid: true, requiresAttachment: false, defaultDays: 22);
  static const _sick = LeaveType(id: 2, name: 'Sick', isPaid: true, requiresAttachment: true, defaultDays: 90);
  static const _unpaid = LeaveType(id: 3, name: 'Unpaid', isPaid: false, requiresAttachment: false);
  static const _me = PersonRef(1, 'You');

  int _nextId = 3;
  final _requests = <LeaveRequest>[
    LeaveRequest(id: 1, user: _me, type: _annual, start: DateTime(2026, 3, 2), end: DateTime(2026, 3, 6), days: 5,
        status: LeaveStatus.approved, approver: const PersonRef(9, 'Manager'), approverComment: 'Enjoy', canCancel: false),
    LeaveRequest(id: 2, user: const PersonRef(2, 'Tariro'), type: _annual, start: DateTime(2026, 11, 16), end: DateTime(2026, 11, 18),
        days: 3, status: LeaveStatus.pending, reason: 'Graduation', canDecide: true),
  ];

  @override
  Future<List<LeaveType>> types() async => [_annual, _sick, _unpaid];

  @override
  Future<({int year, List<LeaveBalance> balances})> balances({int? year}) async {
    final y = year ?? DateTime.now().year;
    double sum(LeaveType t, LeaveStatus s) =>
        _requests.where((r) => r.user?.id == _me.id && r.type.id == t.id && r.status == s).fold(0, (a, r) => a + r.days);
    LeaveBalance b(LeaveType t) {
      final used = sum(t, LeaveStatus.approved), pending = sum(t, LeaveStatus.pending);
      return LeaveBalance(type: t, year: y, entitled: t.defaultDays, used: used, pending: pending,
          remaining: t.defaultDays - used, available: t.isPaid ? t.defaultDays - used - pending : null);
    }
    return (year: y, balances: [b(_annual), b(_sick), b(_unpaid)]);
  }

  @override
  Future<List<LeaveRequest>> myRequests({LeaveStatus? status}) async =>
      _requests.where((r) => r.user?.id == _me.id && (status == null || r.status == status)).toList();

  @override
  Future<LeaveRequest> request(int id) async => _requests.firstWhere((r) => r.id == id);

  @override
  Future<LeaveRequest> apply(LeaveApplication a) async {
    final type = (await types()).firstWhere((t) => t.id == a.typeId);
    final r = LeaveRequest(id: _nextId++, user: _me, type: type, start: a.start, end: a.end, days: (await workingDays(a.start, a.end)).toDouble(),
        status: LeaveStatus.pending, reason: a.reason, hasAttachment: a.attachmentBytes != null, createdAt: DateTime.now(), canCancel: true);
    _requests.add(r);
    return r;
  }

  LeaveRequest _replace(int id, LeaveStatus status, {String? comment}) {
    final i = _requests.indexWhere((r) => r.id == id);
    final r = _requests[i];
    final now = DateTime.now();
    return _requests[i] = LeaveRequest(
      id: r.id, user: r.user, type: r.type, start: r.start, end: r.end, days: r.days, status: status, reason: r.reason,
      createdAt: r.createdAt, approver: status == LeaveStatus.cancelled ? null : _me, approverComment: comment,
      decidedAt: status == LeaveStatus.cancelled ? null : now, cancelledAt: status == LeaveStatus.cancelled ? now : null,
    );
  }

  @override
  Future<LeaveRequest> cancel(int id) async => _replace(id, LeaveStatus.cancelled);

  @override
  Future<List<LeaveRequest>> pending() async => _requests.where((r) => r.canDecide && r.status == LeaveStatus.pending).toList();

  @override
  Future<LeaveRequest> approve(int id, {String? comment}) async => _replace(id, LeaveStatus.approved, comment: comment);

  @override
  Future<LeaveRequest> reject(int id, String comment) async => _replace(id, LeaveStatus.rejected, comment: comment);

  @override
  Future<TeamCalendar> calendar(DateTime from, DateTime to) async => TeamCalendar(
        from: from,
        to: to,
        requests: _requests.where((r) => r.status != LeaveStatus.rejected && r.status != LeaveStatus.cancelled).toList(),
        holidays: [PublicHoliday('Unity Day', DateTime(from.year, 12, 22))],
      );

  @override
  Future<int> workingDays(DateTime start, DateTime end) async => countWeekdays(start, end);
}

// Offline fallback for the apply screen's live count (no holidays).
int countWeekdays(DateTime start, DateTime end) {
  var n = 0;
  for (var d = DateTime(start.year, start.month, start.day); !d.isAfter(end); d = d.add(const Duration(days: 1))) {
    if (d.weekday != DateTime.saturday && d.weekday != DateTime.sunday) n++;
  }
  return n;
}
