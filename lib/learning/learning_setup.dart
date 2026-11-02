import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../db/repository.dart';
import 'course_catalogue.dart';
import 'db/learning_store.dart';
import 'models/learning_models.dart';

const _uuid = Uuid();

class TopicDraft {
  TopicDraft({String? uuid, required this.title, this.plannedSessions = 1, this.isAssessed = true, this.uploaded = false})
      : uuid = uuid ?? _uuid.v4();

  final String uuid;
  String title;
  int plannedSessions;
  bool isAssessed;
  final bool uploaded; // already in the CRM: can be renamed, not removed

  Map<String, dynamic> toJson(int position) =>
      {'client_uuid': uuid, 'position': position, 'title': title, 'planned_sessions': plannedSessions, 'is_assessed': isAssessed};
}

class NewStudent {
  NewStudent({required this.fullName, this.gender, this.age, this.phone, this.location, this.studentRef});

  final String fullName;
  final String? gender; // F | M | Other
  final int? age;
  final String? phone;
  final String? location;
  final String? studentRef;
}

// What a teacher sets up on the device. Each action updates the class as
// shown in the app straight away and queues the matching item for POST
// /learning/setup, so it all works offline and uploads on the next sync.
class LearningSetup {
  final _repo = Repository();

  Future<(LearningStore, int, String)> _ctx() async {
    final user = await _repo.getCurrentUser();
    return (await LearningStore.open(), user?['userId'] as int? ?? 0, user?['name'] as String? ?? '');
  }

  // A class on a course from the CRM's list, with the topics this teacher
  // will teach. The course itself isn't changed; the topics belong to this
  // class only.
  Future<String> createClass({
    required CatalogueCourse course,
    required List<TopicDraft> topics,
    required String className,
    String? venue,
    String? startDate,
    String? endDate,
  }) async {
    final (store, userId, userName) = await _ctx();
    final cohortUuid = _uuid.v4();
    final topicJson = [for (var i = 0; i < topics.length; i++) {...topics[i].toJson(i + 1), 'class_topic': true}];

    await store.saveCohort({
      'client_uuid': cohortUuid,
      'local': true,
      'name': className,
      'venue': venue,
      'status': 'running',
      'start_date': startDate,
      'end_date': endDate,
      'my_role': 'lead',
      'checksum': '',
      'course': {'client_uuid': course.clientUuid, 'code': course.code, 'title': course.title, 'description': course.description, 'topics': topicJson},
      'roster': <dynamic>[],
      'registered': <dynamic>[],
      'sessions': <dynamic>[],
      'records': <dynamic>[],
      'topic_progress': <dynamic>[],
      'progress': <String, dynamic>{},
    }, userId);

    await store.saveSetupItem(
      SetupItem(clientUuid: cohortUuid, kind: 'cohort', cohortUuid: cohortUuid, json: {
        'client_uuid': cohortUuid, 'course_client_uuid': course.clientUuid, 'name': className,
        'venue': venue, 'start_date': startDate, 'end_date': endDate,
        'topics': [for (final t in topicJson) {...t}..remove('class_topic')],
      }),
      ownerUserId: userId, ownerName: userName,
    );
    return cohortUuid;
  }

  // Add or rename the class's own topics. The class item is queued again
  // with the full list; the CRM upserts topics by client_uuid.
  Future<void> updateClassTopics(LearningCohort cohort, List<TopicDraft> topics) async {
    final (store, userId, userName) = await _ctx();
    // Topics shared by the course stay first, untouched.
    final shared = cohort.topics.where((t) => !t.isClassTopic && !cohort.isLocal).map((t) => t.json).toList();
    final own = [for (var i = 0; i < topics.length; i++) {...topics[i].toJson(shared.length + i + 1), 'class_topic': true}];

    final json = Map<String, dynamic>.of(cohort.json);
    json['course'] = {...cohort.course, 'topics': [...shared, ...own]};
    await store.saveCohort(json, userId);
    await store.saveSetupItem(
      SetupItem(clientUuid: cohort.uuid, kind: 'cohort', cohortUuid: cohort.uuid, json: {
        'client_uuid': cohort.uuid, 'course_client_uuid': cohort.courseUuid, 'name': cohort.name,
        'venue': cohort.venue, 'start_date': cohort.startDate, 'end_date': cohort.endDate,
        'topics': [for (final t in own) {...t}..remove('class_topic')],
      }),
      ownerUserId: userId, ownerName: userName,
    );
  }

  // An existing beneficiary (from the CRM search).
  Future<void> enrolExisting(LearningCohort cohort, Map<String, dynamic> beneficiary, {String? studentRef}) async {
    final enrollmentUuid = _uuid.v4();
    await _enrol(cohort, enrollmentUuid, {
      'client_uuid': enrollmentUuid,
      'cohort_client_uuid': cohort.uuid,
      'beneficiary_id': beneficiary['beneficiary_id'] ?? beneficiary['id'],
      'student_ref': studentRef,
      'enrolled_at': DateFormat('yyyy-MM-dd').format(DateTime.now()),
    }, {
      'name': beneficiary['name'] ?? beneficiary['full_name'],
      'gender': beneficiary['gender'],
      'age': beneficiary['age'],
      'phone_number': beneficiary['phone_number'],
      'location': beneficiary['location'],
      'beneficiary_id': beneficiary['beneficiary_id'] ?? beneficiary['id'],
      'student_ref': studentRef,
    });
  }

  // Someone not yet in the CRM: becomes a new beneficiary profile there.
  Future<void> enrolNew(LearningCohort cohort, NewStudent s) async {
    final (store, userId, userName) = await _ctx();
    final studentUuid = _uuid.v4();
    final enrollmentUuid = _uuid.v4();
    await store.saveSetupItem(
      SetupItem(clientUuid: studentUuid, kind: 'student', cohortUuid: cohort.uuid, json: {
        'client_uuid': studentUuid, 'full_name': s.fullName, 'gender': s.gender, 'age': s.age,
        'location': s.location, 'phone_number': s.phone,
      }),
      ownerUserId: userId, ownerName: userName,
    );
    await _enrol(cohort, enrollmentUuid, {
      'client_uuid': enrollmentUuid,
      'cohort_client_uuid': cohort.uuid,
      'student_client_uuid': studentUuid,
      'student_ref': s.studentRef,
      'enrolled_at': DateFormat('yyyy-MM-dd').format(DateTime.now()),
    }, {
      'name': s.fullName,
      'gender': s.gender,
      'age': s.age,
      'phone_number': s.phone,
      'location': s.location,
      'student_ref': s.studentRef,
    });
  }

  Future<void> _enrol(LearningCohort cohort, String enrollmentUuid, Map<String, dynamic> item, Map<String, dynamic> display) async {
    final (store, userId, userName) = await _ctx();
    final entry = {
      'client_uuid': enrollmentUuid,
      'status': 'active',
      'enrolled_at': item['enrolled_at'],
      'attendance_pct': null,
      'at_risk': <dynamic>[],
      ...display,
    };
    // Re-read: the class may have changed since the screen loaded it.
    final current = await store.cohort(cohort.uuid) ?? cohort;
    final json = Map<String, dynamic>.of(current.json);
    json['roster'] = [...current.roster.map((r) => r.json), entry];
    await store.saveCohort(json, userId);
    // _roster_entry is for showing the student until the CRM confirms; it's
    // stripped before upload.
    await store.saveSetupItem(
      SetupItem(clientUuid: enrollmentUuid, kind: 'enrollment', cohortUuid: cohort.uuid, json: {...item, '_roster_entry': entry}),
      ownerUserId: userId, ownerName: userName,
    );
  }
}
