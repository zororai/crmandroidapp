import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../data_collection/sync/sync_runner.dart';

const _cacheKey = 'learning_catalogue';

// One course on the CRM's course list — which is also the list of skill
// interests in beneficiary profiling (the code is what a profile stores).
class CatalogueCourse {
  const CatalogueCourse({required this.code, required this.title, this.clientUuid, this.description});

  final String code;
  final String title;
  final String? clientUuid; // null only for the built-in fallback list
  final String? description;

  factory CatalogueCourse.fromJson(Map<String, dynamic> j) => CatalogueCourse(
        code: j['code'] as String,
        title: j['title'] as String? ?? j['code'] as String,
        clientUuid: j['client_uuid'] as String?,
        description: j['description'] as String?,
      );

  Map<String, dynamic> toJson() => {'code': code, 'title': title, 'client_uuid': clientUuid, 'description': description};
}

// The skills profiling offered before the list came from the CRM. Used
// until the device has downloaded the list once (codes match the CRM's
// starting courses, so answers stay valid).
const builtInSkills = [
  CatalogueCourse(code: 'tailoring', title: 'Tailoring'),
  CatalogueCourse(code: 'ict_digital', title: 'ICT/Digital'),
  CatalogueCourse(code: 'agriculture', title: 'Agriculture'),
  CatalogueCourse(code: 'handicrafts', title: 'Handicrafts'),
  CatalogueCourse(code: 'hair_dressing', title: 'Hair dressing'),
  CatalogueCourse(code: 'cosmetology', title: 'Cosmetology'),
  CatalogueCourse(code: 'mechanics', title: 'Mechanics'),
  CatalogueCourse(code: 'building', title: 'Building'),
  CatalogueCourse(code: 'carpentry', title: 'Carpentry'),
  CatalogueCourse(code: 'food_processing', title: 'Food Processing'),
  CatalogueCourse(code: 'nurse_aide', title: 'Nurse aide'),
  CatalogueCourse(code: 'teaching', title: 'Teaching'),
  CatalogueCourse(code: 'hotel_catering', title: 'Hotel and Catering'),
  CatalogueCourse(code: 'baking', title: 'Baking'),
  CatalogueCourse(code: 'welding', title: 'Welding'),
  CatalogueCourse(code: 'graphic_design', title: 'Graphic Designing'),
];

// The course list as last downloaded, kept for offline use.
class CourseCatalogueCache {
  // Cached list; the built-in skills if it was never downloaded.
  static Future<List<CatalogueCourse>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw != null) {
        return (jsonDecode(raw) as List).cast<Map<String, dynamic>>().map(CatalogueCourse.fromJson).toList();
      }
    } catch (_) {}
    return builtInSkills;
  }

  static Future<bool> isDownloaded() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_cacheKey) != null;
    } catch (_) {
      return false;
    }
  }

  static Future<void> save(List<Map<String, dynamic>> courses) async {
    final list = courses.map(CatalogueCourse.fromJson).map((c) => c.toJson()).toList();
    await (await SharedPreferences.getInstance()).setString(_cacheKey, jsonEncode(list));
  }

  // Best effort: fetch the latest list. Returns it (or the cached one when
  // offline).
  static Future<List<CatalogueCourse>> refresh() async {
    try {
      final sync = await SyncRunner.learningSync();
      if (sync != null) await save(await sync.api.catalogue());
    } catch (_) {}
    return load();
  }
}
