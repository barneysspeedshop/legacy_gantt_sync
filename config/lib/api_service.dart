import 'dart:convert';
import 'dart:developer';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class ApiService {
  final String baseUrl;
  final SharedPreferences prefs;

  ApiService(this.baseUrl, this.prefs);

  Future<bool> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        body: jsonEncode({'username': username, 'password': password}),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['accessToken'] != null) {
          await prefs.setString('accessToken', data['accessToken']);
        }
        // Handle optional refresh token
        if (data['refreshToken'] != null) {
          await prefs.setString('refreshToken', data['refreshToken']);
        }
        return true;
      }
      log('Login Failed: ${response.statusCode} - ${response.body}');
      return false;
    } catch (e) {
      log('Login Error: $e');
      return false;
    }
  }

  Future<void> logout() async {
    await prefs.remove('accessToken');
    await prefs.remove('refreshToken');
  }

  String? get accessToken => prefs.getString('accessToken');

  Map<String, String> get _headers => {'Content-Type': 'application/json', 'Authorization': 'Bearer $accessToken'};

  // --- Tenants ---

  Future<List<Tenant>> getTenants() async {
    final response = await http.get(Uri.parse('$baseUrl/api/admin/tenants'), headers: _headers);

    if (response.statusCode == 200) {
      final List<dynamic> list = jsonDecode(response.body);
      return list.map((json) => Tenant.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load tenants: ${response.body}');
    }
  }

  Future<void> createTenant(String name, String adminUser, String adminPass) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/admin/tenants'),
      headers: _headers,
      body: jsonEncode({'tenantName': name, 'adminUsername': adminUser, 'adminPassword': adminPass}),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to create tenant: ${response.body}');
    }
  }

  Future<void> deleteTenant(String tenantId) async {
    final response = await http.delete(Uri.parse('$baseUrl/api/admin/tenants/$tenantId'), headers: _headers);

    if (response.statusCode != 200) {
      throw Exception('Failed to delete tenant: ${response.body}');
    }
  }

  Future<void> undeleteTenant(String tenantId) async {
    final response = await http.post(Uri.parse('$baseUrl/api/admin/tenants/$tenantId/undelete'), headers: _headers);

    if (response.statusCode != 200) {
      throw Exception('Failed to restore tenant: ${response.body}');
    }
  }

  // --- Users ---

  Future<List<User>> getUsersByTenant(String tenantId) async {
    final response = await http.get(Uri.parse('$baseUrl/api/admin/tenants/$tenantId/users'), headers: _headers);

    if (response.statusCode == 200) {
      final List<dynamic> list = jsonDecode(response.body);
      return list.map((json) => User.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load users: ${response.body}');
    }
  }

  Future<void> createUser(String tenantId, String username, String password, String role) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/users'),
      headers: _headers,
      body: jsonEncode({'tenantId': tenantId, 'username': username, 'password': password, 'role': role}),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to create user: ${response.body}');
    }
  }

  Future<void> revokeUser(String userId) async {
    final response = await http.delete(Uri.parse('$baseUrl/api/users/$userId'), headers: _headers);

    if (response.statusCode != 200) {
      throw Exception('Failed to revoke user: ${response.body}');
    }
  }

  Future<void> undeleteUser(String userId) async {
    final response = await http.post(Uri.parse('$baseUrl/api/users/$userId/undelete'), headers: _headers);

    if (response.statusCode != 200) {
      throw Exception('Failed to restore user: ${response.body}');
    }
  }

  Future<void> kickUser(String userId) async {
    final response = await http.post(Uri.parse('$baseUrl/api/users/$userId/kick'), headers: _headers);

    if (response.statusCode != 200) {
      throw Exception('Failed to kick user: ${response.body}');
    }
  }
}
