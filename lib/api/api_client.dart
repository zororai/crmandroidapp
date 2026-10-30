import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _baseUrlPrefKey = 'api_base_url';

class ApiClient {
  static String? _token;

  // Chosen by the user in the server dialog and persisted on the device, so
  // field devices can point at a LAN IP (e.g. http://192.168.10.149/api/).
  static String? baseUrl;

  static Future<void> loadBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_baseUrlPrefKey);
  }

  static Future<void> saveBaseUrl(String url) async {
    baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlPrefKey, url);
  }

  // Accepts "192.168.10.149", "yazcrm.test", "http://host/api" etc. and
  // returns "http://host/api/". Null if it isn't a usable address.
  static String? normalizeBaseUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return null;
    if (!url.contains('://')) url = 'http://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.endsWith('/api')) url = '$url/api';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return '$url/';
  }

  static void setToken(String? token) => _token = token;

  static Map<String, String> _headers({bool json = false}) => {
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  static Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await http.post(
      Uri.parse('${baseUrl}auth/login'),
      headers: _headers(json: true),
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      // 422 = wrong credentials / bad email, 403 = account disabled. Surface
      // Laravel's own message rather than just the status code.
      String? message;
      try {
        message = (jsonDecode(res.body) as Map<String, dynamic>)['message'] as String?;
      } catch (_) {}
      throw LoginRejected(message ?? 'Login failed (${res.statusCode})');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> searchByPhone(String phone) async {
    final res = await http.get(
      Uri.parse('${baseUrl}beneficiary-attendances/search?phone=$phone'),
      headers: _headers(),
    );
    if (res.statusCode != 200) return [];
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['results'] as List<dynamic>;
  }

  // Same shape BeneficiaryAttendanceController::sync validates on the
  // Laravel side — client_uuid on every record makes a repeated call safe.
  static Future<Map<String, dynamic>> sync(List<Map<String, dynamic>> activities) async {
    final res = await http.post(
      Uri.parse('${baseUrl}beneficiary-attendances/sync'),
      headers: _headers(json: true),
      body: jsonEncode({'activities': activities}),
    );
    if (res.statusCode != 200) {
      throw Exception('Sync failed (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> searchProfilesByPhone(String phone) async {
    final res = await http.get(
      Uri.parse('${baseUrl}beneficiary-profiles/search?phone=$phone'),
      headers: _headers(),
    );
    if (res.statusCode != 200) return [];
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['results'] as List<dynamic>;
  }

  // BeneficiaryProfileController::sync — idempotent via client_uuid.
  static Future<Map<String, dynamic>> syncProfiles(List<Map<String, dynamic>> profiles) async {
    final res = await http.post(
      Uri.parse('${baseUrl}beneficiary-profiles/sync'),
      headers: _headers(json: true),
      body: jsonEncode({'profiles': profiles}),
    );
    if (res.statusCode != 200) {
      throw Exception('Profile sync failed (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

// The server answered but refused the login — distinct from being offline.
class LoginRejected implements Exception {
  LoginRejected(this.message);
  final String message;

  @override
  String toString() => message;
}
