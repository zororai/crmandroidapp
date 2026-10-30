// Shapes exchanged with the CRM's /api/v1 data collection endpoints.

// One entry of GET /forms (and of GET /sync/status `forms`).
class RemoteForm {
  const RemoteForm({required this.id, required this.title, required this.version, this.checksum, this.updatedAt});

  final int id;
  final String title;
  final String version;
  final String? checksum;
  final DateTime? updatedAt;

  factory RemoteForm.fromJson(Map<String, dynamic> json) => RemoteForm(
        id: json['id'] is int ? json['id'] as int : int.parse('${json['id']}'),
        title: '${json['title'] ?? ''}',
        version: '${json['version'] ?? ''}',
        checksum: json['checksum']?.toString(),
        updatedAt: json['updated_at'] == null ? null : DateTime.tryParse('${json['updated_at']}'),
      );
}

class SyncStatusInfo {
  const SyncStatusInfo({required this.forms, this.serverTime});

  final List<RemoteForm> forms;
  final DateTime? serverTime;
}

class MediaReference {
  const MediaReference({required this.field, required this.fileName, required this.mimeType, required this.sizeBytes});

  final String field;
  final String fileName;
  final String mimeType;
  final int sizeBytes;

  Map<String, dynamic> toJson() => {'field': field, 'filename': fileName, 'mime_type': mimeType, 'size': sizeBytes};
}

// One item of POST /submissions/batch.
class SubmissionPayload {
  const SubmissionPayload({
    required this.clientUuid,
    required this.formId,
    required this.formVersion,
    required this.collectedAt,
    required this.deviceId,
    required this.appVersion,
    required this.data,
    this.lat,
    this.lng,
    this.media = const [],
  });

  final String clientUuid;
  final int formId;
  final String formVersion;
  final DateTime collectedAt;
  final String deviceId;
  final String appVersion;
  final double? lat;
  final double? lng;
  final Map<String, dynamic> data; // field name → value; repeats are lists of maps
  final List<MediaReference> media;

  Map<String, dynamic> toJson() => {
        'client_uuid': clientUuid,
        'form_id': formId,
        'form_version': formVersion,
        'collected_at': collectedAt.toUtc().toIso8601String(),
        'device_id': deviceId,
        'app_version': appVersion,
        'lat': lat,
        'lng': lng,
        'data': data,
        'media': [for (final m in media) m.toJson()],
      };
}

enum BatchItemStatus { accepted, duplicate, rejected }

// The server's verdict on one submission in a batch.
class BatchItemResult {
  const BatchItemResult({required this.clientUuid, required this.status, this.reason});

  final String clientUuid;
  final BatchItemStatus status;
  final String? reason;

  // A duplicate means an earlier attempt already got through.
  bool get isStored => status != BatchItemStatus.rejected;

  factory BatchItemResult.fromJson(Map<String, dynamic> json) => BatchItemResult(
        clientUuid: '${json['client_uuid']}',
        status: BatchItemStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => BatchItemStatus.rejected,
        ),
        reason: json['reason']?.toString(),
      );
}
