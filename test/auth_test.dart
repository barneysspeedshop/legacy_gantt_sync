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
  final superUserUsername = 'auto_superuser@admin.com';
  final superUserPassword = 'superpassword';
  late String superUserId;

  setUpAll(() async {
    final portCompleter = Completer<int>();

    // Start server with specific port and secret
    // Note: Depends on local Postgres being available as per server config
    serverProcess = await Process.start(
      'dart',
      ['bin/server.dart'],
      environment: {
        'LEGACY_GANTT_SYNC_PORT': '0',
        'JWT_SECRET': secret,
        'DB_HOST': 'localhost', // Ensure these match your environment
        'DB_PORT': Platform.environment['TEST_DB_PORT']!,
        'DB_USER': 'dart_user',
        'DB_PASS': Platform.environment['TEST_DB_PASS']!,
        'DB_NAME': 'legacy_gantt',
        'REDIS_HOST': '127.0.0.1',
        'REDIS_PORT': Platform.environment['TEST_REDIS_PORT']!,
        'SOLVER_API_KEY': 'test_solver_key',
        'DB_SSL_MODE': 'disable',
      },
    );

    // Listen to stdout to capture the port
    serverProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          print('[Server Out] $line');
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
    serverProcess!.stderr
        .transform(utf8.decoder)
        .listen((line) => print('[Server Err] $line'));

    // Wait for server startup
    port = await portCompleter.future.timeout(const Duration(seconds: 10));
    host = 'http://localhost:$port';
    print('Auth Test Server started on port $port');

    // Create Superuser explicitly via DB
    final connection = await Connection.open(
      Endpoint(
        host: 'localhost',
        database: 'legacy_gantt',
        username: 'dart_user',
        password: Platform.environment['TEST_DB_PASS']!,
        port: int.parse(Platform.environment['TEST_DB_PORT']!),
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    try {
      superUserId = 'auth_test_superuser';
      final passwordHash = BCrypt.hashpw(superUserPassword, BCrypt.gensalt());

      // Create system tenant
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

  group('Auth Flow', () {
    String? adminToken;
    String? tenantId;
    String? userId;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tenantName = 'TestTenant_$timestamp';
    final adminUsername = 'admin_$timestamp';
    final userUsername = 'user1_$timestamp';

    test('Register Tenant (via Superuser)', () async {
      // 1. Superuser login
      final loginRes = await http.post(
        Uri.parse('$host/auth/login'),
        body: jsonEncode({
          'username': superUserUsername,
          'password': superUserPassword,
        }),
      );
      expect(loginRes.statusCode, 200, reason: 'Superuser login failed');
      final superToken = jsonDecode(loginRes.body)['accessToken'];

      // 2. Create Tenant
      final response = await http.post(
        Uri.parse('$host/api/admin/tenants'),
        headers: {'Authorization': 'Bearer $superToken'},
        body: jsonEncode({
          'tenantName': tenantName,
          'adminUsername': adminUsername,
          'adminPassword': 'password',
        }),
      );

      expect(
        response.statusCode,
        200,
        reason: 'Tenant creation failed: ${response.body}',
      );
      final body = jsonDecode(response.body);
      tenantId = body['tenantId'];
      expect(tenantId, isNotNull);
    });

    test('Login Tenant Admin', () async {
      final response = await http.post(
        Uri.parse('$host/auth/login'),
        body: jsonEncode({'username': adminUsername, 'password': 'password'}),
      );

      expect(response.statusCode, 200, reason: 'Admin login failed');
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

      expect(
        response.statusCode,
        200,
        reason: 'User creation failed: ${response.body}',
      );

      final body = jsonDecode(response.body);
      userId = body['userId'];
      expect(userId, isNotNull);
    });

    test('Login as New User', () async {
      final response = await http.post(
        Uri.parse('$host/auth/login'),
        body: jsonEncode({'username': userUsername, 'password': 'userpass'}),
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body);
      expect(body['accessToken'], isNotNull);
    });

    test('Revoke User', () async {
      final response = await http.delete(
        Uri.parse('$host/api/users/$userId'),
        headers: {'Authorization': 'Bearer $adminToken'},
      );
      expect(response.statusCode, 200);
    });

    test('Login as Revoked User fails', () async {
      final response = await http.post(
        Uri.parse('$host/auth/login'),
        body: jsonEncode({'username': userUsername, 'password': 'userpass'}),
      );

      // Expect forbidden because we check isActive in login
      expect(response.statusCode, 403);
    });
  });
}
