import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yazcrm_beneficiary_flutter/data_collection/api/data_collection_api.dart';
import 'package:yazcrm_beneficiary_flutter/leave/api/leave_api.dart';
import 'package:yazcrm_beneficiary_flutter/leave/models/leave_models.dart';
import 'package:yazcrm_beneficiary_flutter/leave/widgets/leave_widgets.dart';

// The shapes below are copied from the CRM's LeaveRequestResource and
// LeaveSummary, so a server-side rename breaks this test, not the app.
Map<String, dynamic> requestJson({String status = 'pending', bool canCancel = true, bool canDecide = false}) => {
      'id': 7,
      'user': {'id': 3, 'name': 'Tariro Moyo'},
      'leave_type': {'id': 1, 'name': 'Annual', 'default_days': 22, 'requires_attachment': false, 'is_paid': true, 'is_active': true},
      'start_date': '2026-03-02',
      'end_date': '2026-03-06',
      'days': 5,
      'reason': 'Family visit',
      'has_attachment': false,
      'status': status,
      'approver': null,
      'approver_comment': null,
      'created_at': '2026-02-20T08:00:00+00:00',
      'decided_at': null,
      'cancelled_at': null,
      'corrected_at': null,
      'correction_reason': null,
      'can': {'cancel': canCancel, 'decide': canDecide},
    };

HttpLeaveApi apiWith(Future<http.Response> Function(http.Request) handler) =>
    HttpLeaveApi(baseUrl: 'http://crm.test/api/', token: 'tok', client: MockClient(handler));

void main() {
  test('reads balances, including unpaid leave with no limit', () async {
    final api = apiWith((req) async {
      expect(req.url.toString(), 'http://crm.test/api/v1/leave/balances');
      expect(req.headers['Authorization'], 'Bearer tok');
      return http.Response(jsonEncode({
        'year': 2026,
        'balances': [
          {
            'leave_type': {'id': 1, 'name': 'Annual', 'is_paid': true, 'requires_attachment': false},
            'year': 2026, 'entitled_days': 22, 'used_days': 5, 'pending_days': 2.5, 'remaining_days': 17, 'available_days': 14.5,
          },
          {
            'leave_type': {'id': 6, 'name': 'Unpaid', 'is_paid': false, 'requires_attachment': false},
            'year': 2026, 'entitled_days': 0, 'used_days': 3, 'pending_days': 0, 'remaining_days': -3, 'available_days': null,
          },
        ],
      }), 200);
    });

    final result = await api.balances();
    expect(result.year, 2026);
    expect(result.balances.first.available, 14.5);
    expect(result.balances.last.type.isPaid, isFalse);
    expect(result.balances.last.available, isNull);
  });

  test('parses a request and the server\'s permission flags', () async {
    final api = apiWith((_) async => http.Response(jsonEncode({'data': requestJson()}), 200));

    final r = await api.request(7);
    expect(r.status, LeaveStatus.pending);
    expect(r.user?.name, 'Tariro Moyo');
    expect(r.days, 5);
    expect(r.canCancel, isTrue);
    expect(r.canDecide, isFalse);
    expect(r.covers(DateTime(2026, 3, 4)), isTrue);
    expect(r.covers(DateTime(2026, 3, 7)), isFalse);
  });

  test('a 403 carries the server\'s explanation', () async {
    final api = apiWith((_) async => http.Response(
        jsonEncode({'message': 'The team calendar is for people who approve leave. Ask your administrator if you need it.'}), 403));

    final error = await api.calendar(DateTime(2026, 3), DateTime(2026, 3, 31)).then<Object?>((_) => null, onError: (Object e) => e);
    expect(isForbidden(error), isTrue);
    expect(leaveErrorText(error!), startsWith('The team calendar is for people who approve leave.'));
  });

  test('a 401 (expired or disabled account) asks for a new login', () async {
    final api = apiWith((_) async => http.Response(jsonEncode({'code': 'account_disabled', 'message': 'Disabled'}), 401));

    expect(api.myRequests(), throwsA(isA<AuthExpiredException>()));
  });

  test('a 422 shows the first validation message', () async {
    final api = apiWith((_) async => http.Response(jsonEncode({
          'message': 'This is 3 working day(s)... (and 1 more error)',
          'errors': {
            'end_date': ['This is 3 working day(s), but you only have 2 day(s) of Annual leave left.'],
            'reason': ['Too long'],
          },
        }), 422));

    expect(
      api.apply(LeaveApplication(typeId: 1, start: DateTime(2026, 3, 9), end: DateTime(2026, 3, 11))),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'This is 3 working day(s), but you only have 2 day(s) of Annual leave left.')),
    );
  });

  test('applying without an attachment sends JSON with ISO dates', () async {
    final api = apiWith((req) async {
      expect(req.method, 'POST');
      expect(req.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(req.body), {'leave_type_id': '1', 'start_date': '2026-03-02', 'end_date': '2026-03-06', 'reason': 'Family visit'});
      return http.Response(jsonEncode({'data': requestJson()}), 201);
    });

    final r = await api.apply(LeaveApplication(typeId: 1, start: DateTime(2026, 3, 2), end: DateTime(2026, 3, 6), reason: '  Family visit '));
    expect(r.id, 7);
  });

  test('applying with an attachment sends multipart', () async {
    late http.BaseRequest seen;
    final client = MockClient.streaming((req, body) async {
      seen = req;
      final text = utf8.decode(await body.toBytes(), allowMalformed: true);
      expect(text, contains('name="attachment"; filename="note.jpg"'));
      expect(text, contains('name="leave_type_id"'));
      return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'data': requestJson()}))), 201);
    });
    final api = HttpLeaveApi(baseUrl: 'http://crm.test/api/', token: 'tok', client: client);

    await api.apply(LeaveApplication(
      typeId: 2,
      start: DateTime(2026, 3, 2),
      end: DateTime(2026, 3, 2),
      attachmentBytes: Uint8List.fromList([1, 2, 3]),
      attachmentName: 'note.jpg',
    ));
    expect(seen.headers['Content-Type'], startsWith('multipart/form-data'));
  });

  test('reject sends the comment; the offline day count skips weekends', () async {
    final api = apiWith((req) async {
      expect(req.method, 'PATCH');
      expect(req.url.path, '/api/v1/leave/requests/7/reject');
      expect(jsonDecode(req.body), {'comment': 'Month-end close'});
      return http.Response(jsonEncode({'data': requestJson(status: 'rejected', canCancel: false)}), 200);
    });

    expect((await api.reject(7, ' Month-end close ')).status, LeaveStatus.rejected);
    expect(countWeekdays(DateTime(2026, 3, 5), DateTime(2026, 3, 10)), 4);
    expect(formatDays(2.5), '2.5');
    expect(formatDays(5), '5');
  });
}
