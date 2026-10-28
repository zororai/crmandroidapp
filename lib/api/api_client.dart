import 'dart:convert';
import 'package:http/http.dart' as http;

// Point this at your CRM server. Use the LAN IP for field devices that
// won't have DNS for yazcrm.test, e.g. http://192.168.10.149/api/
// Local dev (Windows desktop build on the same PC as the CRM):
const String apiBaseUrl = 'http://yazcrm.test/api/';
// const String apiBaseUrl = 'http://192.168.10.149/api/';

class ApiClient {
  static String? _token;

  static void setToken(String? token) => _token = token;

  static Map<String, String> _headers({bool json = false}) => {
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  static Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await http.post(
      Uri.parse('${apiBaseUrl}auth/login'),
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
      Uri.parse('${apiBaseUrl}beneficiary-attendances/search?phone=$phone'),
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
      Uri.parse('${apiBaseUrl}beneficiary-attendances/sync'),
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
      Uri.parse('${apiBaseUrl}beneficiary-profiles/search?phone=$phone'),
      headers: _headers(),
    );
    if (res.statusCode != 200) return [];
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['results'] as List<dynamic>;
  }

  // BeneficiaryProfileController::sync — idempotent via client_uuid.
  static Future<Map<String, dynamic>> syncProfiles(List<Map<String, dynamic>> profiles) async {
    final res = await http.post(
      Uri.parse('${apiBaseUrl}beneficiary-profiles/sync'),
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
