import 'dart:typed_data';

// Leave data as the CRM sends it (/api/v1/leave). Plain value classes; the
// server decides everything, including what the viewer may do (`can`).

double _num(Object? v) => (v as num?)?.toDouble() ?? 0;
DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();

// "5" or "2.5" (no trailing .0).
String formatDays(num days) => days == days.roundToDouble() ? days.toInt().toString() : days.toStringAsFixed(1);

class LeaveType {
  const LeaveType({required this.id, required this.name, required this.isPaid, required this.requiresAttachment, this.defaultDays = 0});

  final int id;
  final String name;
  final bool isPaid;
  final bool requiresAttachment;
  final double defaultDays;

  factory LeaveType.fromJson(Map<String, dynamic> j) => LeaveType(
        id: j['id'] as int,
        name: j['name'] as String,
        isPaid: j['is_paid'] as bool? ?? true,
        requiresAttachment: j['requires_attachment'] as bool? ?? false,
        defaultDays: _num(j['default_days']),
      );
}

class LeaveBalance {
  const LeaveBalance({
    required this.type,
    required this.year,
    required this.entitled,
    required this.used,
    required this.pending,
    required this.remaining,
    this.available,
  });

  final LeaveType type;
  final int year;
  final double entitled;
  final double used;
  final double pending;
  final double remaining;
  final double? available; // null for unpaid leave (no limit)

  factory LeaveBalance.fromJson(Map<String, dynamic> j) => LeaveBalance(
        type: LeaveType.fromJson((j['leave_type'] as Map).cast<String, dynamic>()),
        year: j['year'] as int,
        entitled: _num(j['entitled_days']),
        used: _num(j['used_days']),
        pending: _num(j['pending_days']),
        remaining: _num(j['remaining_days']),
        available: j['available_days'] == null ? null : _num(j['available_days']),
      );
}

enum LeaveStatus {
  pending('Pending'),
  approved('Approved'),
  rejected('Rejected'),
  cancelled('Cancelled');

  const LeaveStatus(this.label);
  final String label;

  static LeaveStatus parse(String? s) => LeaveStatus.values.firstWhere((v) => v.name == s, orElse: () => LeaveStatus.pending);
}

class PersonRef {
  const PersonRef(this.id, this.name);
  final int id;
  final String name;

  static PersonRef? fromJson(Object? j) {
    if (j is! Map) return null;
    return PersonRef(j['id'] as int, j['name'] as String? ?? '');
  }
}

class LeaveRequest {
  const LeaveRequest({
    required this.id,
    required this.type,
    required this.start,
    required this.end,
    required this.days,
    required this.status,
    this.user,
    this.reason,
    this.hasAttachment = false,
    this.approver,
    this.approverComment,
    this.createdAt,
    this.decidedAt,
    this.cancelledAt,
    this.correctedAt,
    this.correctionReason,
    this.canCancel = false,
    this.canDecide = false,
  });

  final int id;
  final PersonRef? user;
  final LeaveType type;
  final DateTime start;
  final DateTime end;
  final double days;
  final LeaveStatus status;
  final String? reason;
  final bool hasAttachment;
  final PersonRef? approver;
  final String? approverComment;
  final DateTime? createdAt;
  final DateTime? decidedAt;
  final DateTime? cancelledAt;
  final DateTime? correctedAt;
  final String? correctionReason;
  final bool canCancel;
  final bool canDecide;

  bool covers(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  factory LeaveRequest.fromJson(Map<String, dynamic> j) {
    final can = (j['can'] as Map?)?.cast<String, dynamic>() ?? const {};
    return LeaveRequest(
      id: j['id'] as int,
      user: PersonRef.fromJson(j['user']),
      type: LeaveType.fromJson((j['leave_type'] as Map).cast<String, dynamic>()),
      start: DateTime.parse(j['start_date'] as String),
      end: DateTime.parse(j['end_date'] as String),
      days: _num(j['days']),
      status: LeaveStatus.parse(j['status'] as String?),
      reason: j['reason'] as String?,
      hasAttachment: j['has_attachment'] as bool? ?? false,
      approver: PersonRef.fromJson(j['approver']),
      approverComment: j['approver_comment'] as String?,
      createdAt: _date(j['created_at']),
      decidedAt: _date(j['decided_at']),
      cancelledAt: _date(j['cancelled_at']),
      correctedAt: _date(j['corrected_at']),
      correctionReason: j['correction_reason'] as String?,
      canCancel: can['cancel'] as bool? ?? false,
      canDecide: can['decide'] as bool? ?? false,
    );
  }
}

class PublicHoliday {
  const PublicHoliday(this.name, this.date);
  final String name;
  final DateTime date;

  factory PublicHoliday.fromJson(Map<String, dynamic> j) => PublicHoliday(j['name'] as String, DateTime.parse(j['date'] as String));
}

class TeamCalendar {
  const TeamCalendar({required this.from, required this.to, required this.requests, required this.holidays});
  final DateTime from;
  final DateTime to;
  final List<LeaveRequest> requests;
  final List<PublicHoliday> holidays;
}

// What a new application looks like before it is sent. The attachment is
// held as bytes so it works the same on every platform (web has no paths).
class LeaveApplication {
  const LeaveApplication({
    required this.typeId,
    required this.start,
    required this.end,
    this.reason,
    this.attachmentBytes,
    this.attachmentName,
  });
  final int typeId;
  final DateTime start;
  final DateTime end;
  final String? reason;
  final Uint8List? attachmentBytes;
  final String? attachmentName;
}
