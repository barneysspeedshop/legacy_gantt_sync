import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  Process? serverProcess;
  late int port;
  late String host;
  final secret = 'test_secret_key';

  // Superuser credentials
  final superUserUsername = 'superuser@admin.com';
  final superUserPassword = 'superpassword';
  late String superUserId;

  setUpAll(() async {
    final portCompleter = Completer<int>();

    // Start server
    serverProcess = await Process.start(
      'dart',
      ['bin/server.dart'],
      environment: {
        'LEGACY_GANTT_SYNC_PORT': '0',
        'JWT_SECRET': secret,
        'DB_HOST': 'localhost',
        'DB_PORT': '5432',
        'DB_USER': 'dart_user',
        'DB_PASS': 'dart_password',
        'DB_NAME': 'legacy_gantt',
      },
    );

    serverProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!portCompleter.isCompleted && line.contains('SERVER_START')) {
            try {
              final json = jsonDecode(line);
              if (json['event'] == 'SERVER_START') {
                final data = json['data'];
                final actualPort = data['port'] as int;
                portCompleter.complete(actualPort);
              }
            } catch (_) {}
          }
        });

    port = await portCompleter.future.timeout(const Duration(seconds: 10));
    host = 'http://localhost:$port';
    print('Admin Test Server started on port $port');

    // Manually insert superuser
    final connection = await Connection.open(
      Endpoint(
        host: 'localhost',
        database: 'legacy_gantt',
        username: 'dart_user',
        password: 'dart_password',
        port: 5432,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    try {
      superUserId = 'super-user-id';
      final passwordHash = BCrypt.hashpw(superUserPassword, BCrypt.gensalt());

      // Always create system tenant first
      await connection.execute(
        "INSERT INTO auth.tenants (id, name, is_active) VALUES ('system', 'System', true) ON CONFLICT (id) DO NOTHING",
      );

      // Upsert superuser
      await connection.execute(
        Sql.named(
          'INSERT INTO auth.users (id, username, password_hash, role, tenant_id, is_active) VALUES (@id, @username, @hash, @role, @tenantId, true) ON CONFLICT (id) DO UPDATE SET password_hash = @hash, tenant_id = @tenantId',
        ),
        parameters: {
          'id': superUserId,
          'username': superUserUsername,
          'hash': passwordHash,
          'role': 'superuser',
          'tenantId': 'system',
        },
      );
    } finally {
      await connection.close();
    }
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  group('Superuser', () {
    String? superUserToken;

    test('Login as Superuser', () async {
      final response = await http.post(
        Uri.parse('$host/auth/login'),
        body: jsonEncode({
          'username': superUserUsername,
          'password': superUserPassword,
        }),
      );
      if (response.statusCode != 200) {
        print('Login failed: ${response.body}');
      }
      expect(response.statusCode, 200);
      final body = jsonDecode(response.body);
      superUserToken = body['accessToken'];
      expect(superUserToken, isNotNull);
    });

    test('List All Tenants', () async {
      final response = await http.get(
        Uri.parse('$host/api/admin/tenants'),
        headers: {'Authorization': 'Bearer $superUserToken'},
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as List;
      // Expect at least 'system' (if we created it) or existing tenants
      expect(body, isNotEmpty);
    });

    test('List Users for Tenant', () async {
      // First, create a regular tenant and user to list
      final tenantName =
          'TargetTenant_${DateTime.now().millisecondsSinceEpoch}';
      final adminUser = 'target_admin_${DateTime.now().millisecondsSinceEpoch}';

      final regRes = await http.post(
        Uri.parse('$host/api/admin/tenants'),
        headers: {'Authorization': 'Bearer $superUserToken'},
        body: jsonEncode({
          'tenantName': tenantName,
          'adminUsername': adminUser,
          'adminPassword': 'password',
        }),
      );
      expect(
        regRes.statusCode,
        200,
        reason: 'Tenant creation failed: ${regRes.body}',
      );
      final regBody = jsonDecode(regRes.body);
      final tenantId = regBody['tenantId'];

      // List users
      final response = await http.get(
        Uri.parse('$host/api/admin/tenants/$tenantId/users'),
        headers: {'Authorization': 'Bearer $superUserToken'},
      );
      expect(response.statusCode, 200);
      final users = jsonDecode(response.body) as List;
      expect(users.any((u) => u['username'] == adminUser), isTrue);
    });

    test('Create User in Another Tenant', () async {
      // Create a tenant
      final tenantName = 'CrossTenant_${DateTime.now().millisecondsSinceEpoch}';
      final adminUser = 'cross_admin_${DateTime.now().millisecondsSinceEpoch}';
      final regRes = await http.post(
        Uri.parse('$host/api/admin/tenants'),
        headers: {'Authorization': 'Bearer $superUserToken'},
        body: jsonEncode({
          'tenantName': tenantName,
          'adminUsername': adminUser,
          'adminPassword': 'password',
        }),
      );
      expect(regRes.statusCode, 200);
      final regBody = jsonDecode(regRes.body);
      final tenantId = regBody['tenantId'];

      // Superuser creates user in that tenant
      final newUserName =
          'superuser_created_${DateTime.now().millisecondsSinceEpoch}';
      final createRes = await http.post(
        Uri.parse('$host/api/users'),
        headers: {'Authorization': 'Bearer $superUserToken'},
        body: jsonEncode({
          'username': newUserName,
          'password': 'password',
          'tenantId': tenantId, // Specifying tenant
        }),
      );

      expect(createRes.statusCode, 200);

      // Verify user exists in that tenant
      final listRes = await http.get(
        Uri.parse('$host/api/admin/tenants/$tenantId/users'),
        headers: {'Authorization': 'Bearer $superUserToken'},
      );
      final users = jsonDecode(listRes.body) as List;
      expect(users.any((u) => u['username'] == newUserName), isTrue);
    });

    test('Delete User in Another Tenant', () async {
      // Create a tenant and a user to delete
      final tenantName =
          'DeleteTenant_${DateTime.now().millisecondsSinceEpoch}';
      final adminUser = 'del_admin_${DateTime.now().millisecondsSinceEpoch}';
      final regRes = await http.post(
        Uri.parse('$host/api/admin/tenants'),
        headers: {'Authorization': 'Bearer $superUserToken'},
        body: jsonEncode({
          'tenantName': tenantName,
          'adminUsername': adminUser,
          'adminPassword': 'password',
        }),
      );
      final regBody = jsonDecode(regRes.body);
      final tenantId = regBody['tenantId'];

      // Get the admin user ID from list
      final listRes = await http.get(
        Uri.parse('$host/api/admin/tenants/$tenantId/users'),
        headers: {'Authorization': 'Bearer $superUserToken'},
      );
      final users = jsonDecode(listRes.body) as List;
      final userId = users.firstWhere((u) => u['username'] == adminUser)['id'];

      // Delete user
      final delRes = await http.delete(
        Uri.parse('$host/api/users/$userId'),
        headers: {'Authorization': 'Bearer $superUserToken'},
      );
      expect(delRes.statusCode, 200);

      // Verify deleted/revoked (isActive = false)
      final listRes2 = await http.get(
        Uri.parse('$host/api/admin/tenants/$tenantId/users'),
        headers: {'Authorization': 'Bearer $superUserToken'},
      );
      final users2 = jsonDecode(listRes2.body) as List;
      final updatedUser = users2.firstWhere((u) => u['id'] == userId);
      expect(updatedUser['isActive'], isFalse);
    });

    test('Public Register Disabled', () async {
      final response = await http.post(
        Uri.parse('$host/auth/register'),
        body: jsonEncode({
          'tenantName': 'HackTenant',
          'adminUsername': 'hack',
          'adminPassword': 'hack',
        }),
      );
      expect(response.statusCode, 404);
    });

    test('Privilege Escalation Blocked', () async {
      // Create a regular tenant admin
      final tenantName = 'EscTenant_${DateTime.now().millisecondsSinceEpoch}';
      final adminUser = 'esc_admin_${DateTime.now().millisecondsSinceEpoch}';
      final regRes = await http.post(
        Uri.parse('$host/api/admin/tenants'),
        headers: {'Authorization': 'Bearer $superUserToken'},
        body: jsonEncode({
          'tenantName': tenantName,
          'adminUsername': adminUser,
          'adminPassword': 'password',
        }),
      );
      expect(regRes.statusCode, 200);

      // Login as that admin
      final loginRes = await http.post(
        Uri.parse('$host/auth/login'),
        body: jsonEncode({'username': adminUser, 'password': 'password'}),
      );
      expect(loginRes.statusCode, 200);
      final adminToken = jsonDecode(loginRes.body)['accessToken'];

      // Attempt to create a superuser
      final response = await http.post(
        Uri.parse('$host/api/users'),
        headers: {'Authorization': 'Bearer $adminToken'},
        body: jsonEncode({
          'username': 'hacker',
          'password': 'password',
          'role': 'superuser',
        }),
      );

      expect(response.statusCode, 403);
    });
  });
}
