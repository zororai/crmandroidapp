import 'dart:convert';

// Course delivery data, in the shape GET /api/v1/learning/cohorts sends it.
// A class (cohort) is cached as that JSON. Classes, topics and students are
// identified by client_uuid everywhere in the app: a teacher can create them
// offline, before the CRM has assigned any ids.

class LearningTopic {
  LearningTopic(this.json);
  final Map<String, dynamic> json;

  String get uuid => json['client_uuid'] as String;
  int get position => json['position'] as int? ?? 0;
  String get title => json['title'] as String? ?? '';
  String? get description => json['description'] as String?;
  int get plannedSessions => json['planned_sessions'] as int? ?? 1;
  bool get isAssessed => json['is_assessed'] != false;
  // The teacher's own topic for this class (others are shared by the course).
  bool get isClassTopic => json['class_topic'] == true;
}

class LearningStudent {
  LearningStudent(this.json);
  final Map<String, dynamic> json;

  String get uuid => json['client_uuid'] as String; // the enrollment's client_uuid
  String get name => json['name'] as String? ?? 'Student';
  String? get studentRef => json['student_ref'] as String?;
  String? get gender => json['gender'] as String?;
  int? get age => json['age'] as int?;
  String? get phone => json['phone_number'] as String?;
  String? get location => json['location'] as String?;
  int? get beneficiaryId => json['beneficiary_id'] as int?;
  String get status => json['status'] as String? ?? 'active';
  double? get attendancePct => (json['attendance_pct'] as num?)?.toDouble();
  double? get topicsCoveredPct => (json['topics_covered_pct'] as num?)?.toDouble();
  double? get assessedProgressPct => (json['assessed_progress_pct'] as num?)?.toDouble();
  bool get eligibleForCompletion => json['eligible_for_completion'] == true;
  List<Map<String, dynamic>> get atRisk => ((json['at_risk'] as List?) ?? const []).cast<Map<String, dynamic>>();

  // Dropped/transferred students aren't marked in new sessions.
  bool get isActive => !['dropped', 'transferred'].contains(status);
}

class PlannedSession {
  PlannedSession(this.json);
  final Map<String, dynamic> json;

  int get id => json['id'] as int;
  String get date => json['scheduled_date'] as String;
  String? get startTime => json['start_time'] as String?;
  String? get endTime => json['end_time'] as String?;
  String? get plannedTopicUuid => json['planned_topic_client_uuid'] as String?;
  int? get plannedTopicId => json['planned_topic_id'] as int?;
  String get status => json['status'] as String? ?? 'scheduled';
  bool get isAdHoc => json['is_ad_hoc'] == true;
}

class LearningCohort {
  LearningCohort(this.json);
  final Map<String, dynamic> json;

  String get uuid => json['client_uuid'] as String;
  String get name => json['name'] as String? ?? '';
  String? get venue => json['venue'] as String?;
  String? get startDate => json['start_date'] as String?;
  String? get endDate => json['end_date'] as String?;
  String get status => json['status'] as String? ?? 'running';
  String? get myRole => json['my_role'] as String?;
  String get checksum => json['checksum'] as String? ?? '';
  // Created on this device and not yet confirmed by the CRM.
  bool get isLocal => json['local'] == true;
  Map<String, dynamic> get course => (json['course'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get courseUuid => course['client_uuid'] as String? ?? '';
  String get courseTitle => course['title'] as String? ?? '';
  String? get courseDescription => course['description'] as String?;
  String? get courseCode => course['code'] as String?;
  // A teacher plans their own class: the lead (or whoever set it up here)
  // can add and rename the class's topics.
  bool get canEditTopics => isLocal || myRole == 'lead' || course['can_edit'] == true;
  bool get canEnrol => myRole == 'lead' || isLocal;
  double? get minAttendancePct => (course['min_attendance_pct'] as num?)?.toDouble();
  Map<String, dynamic> get progress => (json['progress'] as Map?)?.cast<String, dynamic>() ?? const {};

  List<LearningTopic> get topics =>
      ((course['topics'] as List?) ?? const []).cast<Map<String, dynamic>>().map(LearningTopic.new).toList()
        ..sort((a, b) => a.position.compareTo(b.position));
  List<LearningStudent> get roster =>
      ((json['roster'] as List?) ?? const []).cast<Map<String, dynamic>>().map(LearningStudent.new).toList();
  List<PlannedSession> get sessions =>
      ((json['sessions'] as List?) ?? const []).cast<Map<String, dynamic>>().map(PlannedSession.new).toList();
  // Recent session records already on the server (with their attendance).
  List<Map<String, dynamic>> get serverRecords => ((json['records'] as List?) ?? const []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get topicProgress => ((json['topic_progress'] as List?) ?? const []).cast<Map<String, dynamic>>();
  // Youth registered for this course in profiling, not yet in this class.
  List<Map<String, dynamic>> get registered {
    final enrolled = roster.map((s) => s.beneficiaryId).whereType<int>().toSet();
    return ((json['registered'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((r) => !enrolled.contains(r['beneficiary_id'] ?? r['id']))
        .toList();
  }

  LearningTopic? topic(String? uuid) => uuid == null ? null : topics.where((t) => t.uuid == uuid).firstOrNull;
  LearningStudent? student(String uuid) => roster.where((s) => s.uuid == uuid).firstOrNull;

  // The server identifies planned topics by id; map to the topic's uuid.
  LearningTopic? plannedTopic(PlannedSession s) =>
      topic(s.plannedTopicUuid) ?? topics.where((t) => t.json['id'] != null && t.json['id'] == s.plannedTopicId).firstOrNull;

  // Server records/progress use ids; these map them to uuids.
  String? topicUuidForId(int? id) => topics.where((t) => t.json['id'] != null && t.json['id'] == id).firstOrNull?.uuid;
  String? studentUuidForId(int? id) => roster.where((s) => s.json['enrollment_id'] != null && s.json['enrollment_id'] == id).firstOrNull?.uuid;
}

// Local lifecycle, same as data collection:
//   draft ──finish──► finalized ──sync──► syncing ──► sent
//                                                └──► failed (server's reason)
enum RecordStatus { draft, finalized, syncing, sent, failed }

// One session recorded (or edited) on this device — an lc_session_records row.
class LocalSessionRecord {
  LocalSessionRecord({
    required this.clientUuid,
    required this.cohortUuid,
    required this.heldOn,
    required this.ownerUserId,
    required this.ownerName,
    this.cohortSessionId,
    this.startedAt,
    this.endedAt,
    this.notes = '',
    this.topics = const [],
    this.attendance = const [],
    this.topicProgress = const [],
    this.status = RecordStatus.draft,
    this.errorReason,
    this.warnings = const [],
    this.attempts = 0,
    this.nextAttemptAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String clientUuid;
  final String cohortUuid;
  final int? cohortSessionId;
  final String heldOn; // yyyy-MM-dd
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String notes;
  final List<Map<String, dynamic>> topics; // {topic_client_uuid, coverage: full|partial, note}
  final List<Map<String, dynamic>> attendance; // {enrollment_client_uuid, status, arrived_at, reason, marked_at}
  final List<Map<String, dynamic>> topicProgress; // {enrollment_client_uuid, topic_client_uuid, status, score}
  final RecordStatus status;
  final String? errorReason;
  final List<Map<String, dynamic>> warnings;
  final int attempts;
  final DateTime? nextAttemptAt;
  final int ownerUserId;
  final String ownerName;
  final DateTime createdAt;
  final DateTime updatedAt;

  Duration? get duration => startedAt != null && endedAt != null && !endedAt!.isBefore(startedAt!) ? endedAt!.difference(startedAt!) : null;

  bool get isEditable => status != RecordStatus.syncing && status != RecordStatus.sent;

  factory LocalSessionRecord.fromRow(Map<String, dynamic> r) {
    List<Map<String, dynamic>> list(String key) => (jsonDecode(r[key] as String? ?? '[]') as List).cast<Map<String, dynamic>>();
    DateTime? date(String key) => r[key] == null ? null : DateTime.tryParse(r[key] as String);
    return LocalSessionRecord(
      clientUuid: r['clientUuid'] as String,
      cohortUuid: r['cohortUuid'] as String,
      cohortSessionId: r['cohortSessionId'] as int?,
      heldOn: r['heldOn'] as String,
      startedAt: date('startedAt'),
      endedAt: date('endedAt'),
      notes: r['notes'] as String? ?? '',
      topics: list('topics'),
      attendance: list('attendance'),
      topicProgress: list('topicProgress'),
      status: RecordStatus.values.firstWhere((s) => s.name == r['status'], orElse: () => RecordStatus.draft),
      errorReason: r['errorReason'] as String?,
      warnings: list('warnings'),
      attempts: r['attempts'] as int? ?? 0,
      nextAttemptAt: date('nextAttemptAt'),
      ownerUserId: r['ownerUserId'] as int,
      ownerName: r['ownerName'] as String? ?? '',
      createdAt: date('createdAt'),
      updatedAt: date('updatedAt'),
    );
  }

  Map<String, dynamic> toRow() => {
        'clientUuid': clientUuid,
        'cohortUuid': cohortUuid,
        'cohortSessionId': cohortSessionId,
        'heldOn': heldOn,
        'startedAt': startedAt?.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'notes': notes,
        'topics': jsonEncode(topics),
        'attendance': jsonEncode(attendance),
        'topicProgress': jsonEncode(topicProgress),
        'status': status.name,
        'errorReason': errorReason,
        'warnings': jsonEncode(warnings),
        'attempts': attempts,
        'nextAttemptAt': nextAttemptAt?.toIso8601String(),
        'ownerUserId': ownerUserId,
        'ownerName': ownerName,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  // POST /learning/sessions/batch item. Classes, students and topics go by
  // client_uuid, which the CRM resolves — so a session recorded in a class
  // set up offline syncs straight after the class does.
  Map<String, dynamic> toPayload({required String deviceId, required String appVersion}) => {
        'client_uuid': clientUuid,
        'cohort_client_uuid': cohortUuid,
        'cohort_session_id': cohortSessionId,
        'held_on': heldOn,
        'started_at': startedAt?.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
        'device_id': deviceId,
        'app_version': appVersion,
        'lat': null,
        'lng': null,
        'notes': notes,
        'topics': topics,
        'attendance': attendance,
        'topic_progress': topicProgress,
      };
}

class LearningBatchResult {
  LearningBatchResult(this.json);
  final Map<String, dynamic> json;

  String get clientUuid => '${json['client_uuid']}';
  String get kind => json['kind'] as String? ?? '';
  String get status => json['status'] as String? ?? 'rejected';
  String? get reason => json['reason'] as String?;
  String? get serverClientUuid => json['server_client_uuid'] as String?;
  bool get retryable => json['retryable'] == true;
  bool get isStored => status == 'accepted' || status == 'duplicate' || status == 'updated';
  List<Map<String, dynamic>> get warnings => ((json['warnings'] as List?) ?? const []).cast<Map<String, dynamic>>();
}

// Reasons from the server, worded for a teacher.
String describeRejection(String? reason) => switch (reason) {
      'not_facilitator' => 'You are no longer a facilitator of this class.',
      'not_owner' => 'This course was set up by someone else.',
      'unknown_cohort' => 'This class does not exist in the CRM.',
      'unknown_course' => 'The course for this class has not been uploaded.',
      'unknown_student' => 'This student could not be found in the CRM.',
      'unknown_session' => 'The scheduled session was removed in the CRM.',
      'foreign_enrollment' => 'A student in this register is not in this class (any more).',
      'unknown_topic' => 'A topic in this session is not in the course (any more).',
      'duplicate_student' => 'A student was marked twice.',
      'future_date' => 'The session date is in the future.',
      'read_only' => 'This session was imported in the CRM and cannot be changed from the app.',
      'client_uuid_conflict' => 'This record clashes with another one in the CRM.',
      'invalid' => 'Some details are invalid.',
      null => 'Rejected by the CRM.',
      _ => reason,
    };
