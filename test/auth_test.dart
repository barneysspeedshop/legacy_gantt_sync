import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  Process? serverProcess;
  final port = 8081; // Use different port to avoid conflict
  final host = 'http://localhost:$port';
  final secret = 'test_secret_key';

  setUpAll(() async {
    // Start server with specific port and secret
    // Note: Depends on local Postgres being available as per server config
    serverProcess = await Process.start(
      'dart',
      ['bin/server.dart'],
      environment: {
        'LEGACY_GANTT_SYNC_PORT': port.toString(),
        'JWT_SECRET': secret,
        'DB_HOST': 'localhost', // Ensure these match your environment
        'DB_PORT': '5432',
        'DB_USER': 'dart_user',
        'DB_PASS': 'dart_password',
        'DB_NAME': 'legacy_gantt',
      },
    );

    // Wait for server startup
    await Future.delayed(const Duration(seconds: 3));

    serverProcess!.stdout.transform(utf8.decoder).listen((line) => print('[Server Out] $line'));
    serverProcess!.stderr.transform(utf8.decoder).listen((line) => print('[Server Err] $line'));
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  group('Auth Flow', () {
    String? adminToken;
    String? tenantId;
    String? userId;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tenantName = 'TestTenant_$timestamp';
    final adminUsername = 'admin_$timestamp';
    final userUsername = 'user1_$timestamp';

    test('Register Tenant', () async {
      final response = await http.post(
        Uri.parse('$host/auth/register'),
        body: jsonEncode({'tenantName': tenantName, 'adminUsername': adminUsername, 'adminPassword': 'password123'}),
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body);
      tenantId = body['tenantId'];
      expect(tenantId, isNotNull);
    });

    test('Login Tenant Admin', () async {
      final response = await http.post(Uri.parse('$host/auth/login'), body: jsonEncode({'username': adminUsername, 'password': 'password123'}));

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body);
      adminToken = body['accessToken'];
      expect(adminToken, isNotNull);
    });

    test('Create User (as Admin)', () async {
      final response = await http.post(
        Uri.parse('$host/api/users'),
        headers: {'Authorization': 'Bearer $adminToken'},
        body: jsonEncode({'username': userUsername, 'password': 'userpass'}),
      );

      expect(response.statusCode, 200);

      final body = jsonDecode(response.body);
      userId = body['userId'];
      expect(userId, isNotNull);
    });

    test('Login as New User', () async {
      final response = await http.post(Uri.parse('$host/auth/login'), body: jsonEncode({'username': userUsername, 'password': 'userpass'}));

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body);
      expect(body['accessToken'], isNotNull);
    });

    test('Revoke User', () async {
      final response = await http.delete(Uri.parse('$host/api/users/$userId'), headers: {'Authorization': 'Bearer $adminToken'});
      expect(response.statusCode, 200);
    });

    test('Login as Revoked User fails', () async {
      final response = await http.post(Uri.parse('$host/auth/login'), body: jsonEncode({'username': userUsername, 'password': 'userpass'}));

      // Expect forbidden because we check isActive in login
      expect(response.statusCode, 403);
    });
  });
}
