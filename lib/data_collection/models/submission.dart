import 'dart:convert';

import 'api_models.dart';

// Local submission lifecycle:
//   draft ──finalize──► finalized ──sync──► syncing ──► sent
//     ▲                    │                   └──► failed (server rejected it)
//     └── edited before sending, or failed and corrected ──┘
enum SubmissionStatus { draft, finalized, syncing, sent, failed }

SubmissionStatus _status(String? s) =>
    SubmissionStatus.values.firstWhere((v) => v.name == s, orElse: () => SubmissionStatus.draft);

// One filled-in form on this device (a dc_submissions row).
class Submission {
  Submission({
    required this.clientUuid,
    required this.formId,
    required this.formVersion,
    required this.formTitle,
    required this.ownerUserId,
    required this.ownerName,
    required this.status,
    required this.data,
    required this.startedAt,
    required this.updatedAt,
    this.payload,
    this.lat,
    this.lng,
    this.finalizedAt,
    this.sentAt,
    this.dataAccepted = false,
    this.attempts = 0,
    this.nextAttemptAt,
    this.errorReason,
  });

  final String clientUuid;
  final int formId;
  final String formVersion;
  final String formTitle;
  final int ownerUserId;
  final String ownerName;
  final SubmissionStatus status;
  final Map<String, dynamic> data; // working answers, including hidden ones
  final Map<String, dynamic>? payload; // frozen at finalize: hidden answers removed
  final double? lat;
  final double? lng;
  final DateTime startedAt;
  final DateTime updatedAt;
  final DateTime? finalizedAt;
  final DateTime? sentAt;
  final bool dataAccepted; // the server has the answers; only photos may still be pending
  final int attempts;
  final DateTime? nextAttemptAt;
  final String? errorReason;

  bool get isEditable => status == SubmissionStatus.draft || status == SubmissionStatus.finalized || status == SubmissionStatus.failed;

  factory Submission.fromRow(Map<String, dynamic> row) {
    DateTime? date(String key) => row[key] == null ? null : DateTime.tryParse(row[key] as String);
    return Submission(
      clientUuid: row['clientUuid'] as String,
      formId: row['formId'] as int,
      formVersion: row['formVersion'] as String,
      formTitle: row['formTitle'] as String? ?? '',
      ownerUserId: row['ownerUserId'] as int,
      ownerName: row['ownerName'] as String? ?? '',
      status: _status(row['status'] as String?),
      data: jsonDecode(row['data'] as String? ?? '{}') as Map<String, dynamic>,
      payload: row['payload'] == null ? null : jsonDecode(row['payload'] as String) as Map<String, dynamic>,
      lat: (row['lat'] as num?)?.toDouble(),
      lng: (row['lng'] as num?)?.toDouble(),
      startedAt: date('startedAt')!,
      updatedAt: date('updatedAt')!,
      finalizedAt: date('finalizedAt'),
      sentAt: date('sentAt'),
      dataAccepted: row['dataAccepted'] == 1,
      attempts: row['attempts'] as int? ?? 0,
      nextAttemptAt: date('nextAttemptAt'),
      errorReason: row['errorReason'] as String?,
    );
  }

  Map<String, dynamic> toRow() => {
        'clientUuid': clientUuid,
        'formId': formId,
        'formVersion': formVersion,
        'formTitle': formTitle,
        'ownerUserId': ownerUserId,
        'ownerName': ownerName,
        'status': status.name,
        'data': jsonEncode(data),
        'payload': payload == null ? null : jsonEncode(payload),
        'lat': lat,
        'lng': lng,
        'startedAt': startedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'finalizedAt': finalizedAt?.toIso8601String(),
        'sentAt': sentAt?.toIso8601String(),
        'dataAccepted': dataAccepted ? 1 : 0,
        'attempts': attempts,
        'nextAttemptAt': nextAttemptAt?.toIso8601String(),
        'errorReason': errorReason,
      };
}

// A photo/file attached to a submission (a dc_media row). `path` is a file
// path on the device, or a data: URI on web, where files can't be written.
class MediaRecord {
  MediaRecord({
    required this.fileName,
    required this.clientUuid,
    required this.fieldName,
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    this.uploaded = false,
  });

  final String fileName;
  final String clientUuid;
  final String fieldName;
  final String path;
  final String mimeType;
  final int sizeBytes;
  final bool uploaded;

  factory MediaRecord.fromRow(Map<String, dynamic> row) => MediaRecord(
        fileName: row['fileName'] as String,
        clientUuid: row['clientUuid'] as String,
        fieldName: row['fieldName'] as String,
        path: row['path'] as String,
        mimeType: row['mimeType'] as String,
        sizeBytes: row['sizeBytes'] as int,
        uploaded: row['uploaded'] == 1,
      );

  Map<String, dynamic> toRow() => {
        'fileName': fileName,
        'clientUuid': clientUuid,
        'fieldName': fieldName,
        'path': path,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'uploaded': uploaded ? 1 : 0,
      };

  MediaReference get reference => MediaReference(field: fieldName, fileName: fileName, mimeType: mimeType, sizeBytes: sizeBytes);
}
