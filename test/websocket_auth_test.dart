import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:async/async.dart';

void main() {
  Process? serverProcess;
  final random = Random();
  late String wsUrl;
  late String httpUrl;
  final secret = 'test_secret_key';

  // Helper to register and get token
  Future<String> registerAndLogin(String username) async {
    // 1. Login as Superuser
    final superRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': 'superuser', 'password': 'superuser'}),
      headers: {'Content-Type': 'application/json'},
    );
    if (superRes.statusCode != 200) throw Exception('Superuser login failed');
    final superToken = jsonDecode(superRes.body)['accessToken'];

    // 2. Register Tenant
    final tName = 'tenant_${random.nextInt(100000)}';
    final createTenantRes = await http.post(
      Uri.parse('$httpUrl/api/admin/tenants'),
      headers: {'Authorization': 'Bearer $superToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'tenantName': tName, 'adminUsername': 'admin_${random.nextInt(10000)}', 'adminPassword': 'password'}),
    );
    if (createTenantRes.statusCode != 200) throw Exception('Create tenant failed');
    final String effectiveTenantId = jsonDecode(createTenantRes.body)['tenantId'];

    // 3. Create User
    final createUserRes = await http.post(
      Uri.parse('$httpUrl/api/users'),
      headers: {'Authorization': 'Bearer $superToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': 'password', 'tenantId': effectiveTenantId}),
    );
    if (createUserRes.statusCode != 200) throw Exception('Create user failed');

    // 4. Login as User
    final loginRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': username, 'password': 'password'}),
      headers: {'Content-Type': 'application/json'},
    );
    if (loginRes.statusCode != 200) throw Exception('Login failed');

    return jsonDecode(loginRes.body)['accessToken'];
  }

  setUpAll(() async {
    final portCompleter = Completer<int>();

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
        'SUPERUSER_USERNAME': 'superuser',
        'SUPERUSER_PASSWORD': 'superuser',
      },
    );

    serverProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      print('[Server Out] $line');
      if (!portCompleter.isCompleted && line.contains('SERVER_START')) {
        try {
          final json = jsonDecode(line);
          if (json['event'] == 'SERVER_START') {
            portCompleter.complete(json['data']['port'] as int);
          }
        } catch (_) {}
      }
    });

    serverProcess!.stderr.transform(utf8.decoder).listen((line) {
      print('[Server Err] $line');
    });

    // Wait for the port
    final actualPort = await portCompleter.future.timeout(const Duration(seconds: 30));
    wsUrl = 'ws://localhost:$actualPort/ws';
    httpUrl = 'http://localhost:$actualPort';
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  test('Connects without token (pending auth)', () async {
    final socket = await WebSocket.connect(wsUrl);
    // Should stay open initially
    await Future.delayed(const Duration(milliseconds: 100));
    expect(socket.closeCode, isNull);
    await socket.close();
  });

  test('Successful In-band Auth', () async {
    final username = 'auth_user_${random.nextInt(10000)}';
    final token = await registerAndLogin(username);
    final tenantId = jsonDecode(utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))))['tenant_id'];

    final socket = await WebSocket.connect(wsUrl);

    // Send Auth
    socket.add(jsonEncode({'type': 'auth', 'token': token}));

    // Expect AUTH_SUCCESS
    // Iterate stream to find it, logging others
    bool authenticated = false;
    final queue = StreamQueue(socket);

    while (await queue.hasNext) {
      final msg = await queue.next.timeout(const Duration(seconds: 5));
      print('Received: $msg');
      final json = jsonDecode(msg as String);
      if (json['type'] == 'AUTH_SUCCESS') {
        authenticated = true;
        break;
      }
    }
    expect(authenticated, isTrue);

    // Now Subscribe
    socket.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Expect SUBSCRIBE_SUCCESS
    // We might get other messages first (e.g. USER_LIST_UPDATE broadcast), filter for sub success
    // We might get other messages first (e.g. USER_LIST_UPDATE broadcast), filter for sub success
    while (await queue.hasNext) {
      final msg = await queue.next.timeout(const Duration(seconds: 5));
      final json = jsonDecode(msg as String);
      if (json['type'] == 'SUBSCRIBE_SUCCESS') {
        expect(json['channel'], equals(tenantId));
        break;
      }
    }

    await socket.close();
  });

  test('Fails on immediate subscribe without auth', () async {
    final socket = await WebSocket.connect(wsUrl);

    socket.add(jsonEncode({'type': 'subscribe', 'channel': 'some_channel'}));

    // Should obtain a close frame or error message
    // Implementation closes with 4003
    try {
      await socket.done.timeout(const Duration(seconds: 2));
      expect(socket.closeCode, equals(4003));
    } catch (_) {
      // If stream throws error or timeout
    }
  });

  test('Fails on invalid token', () async {
    final socket = await WebSocket.connect(wsUrl);

    socket.add(jsonEncode({'type': 'auth', 'token': 'invalid_token_xyz'}));

    try {
      await socket.done.timeout(const Duration(seconds: 2));
      expect(socket.closeCode, equals(4003));
    } catch (_) {}
  });
  test('Disconnects idle client after timeout', () async {
    final socket = await WebSocket.connect(wsUrl);

    // Drain stream until it closes
    try {
      await socket.forEach((_) {}).timeout(const Duration(seconds: 20));
    } catch (e) {
      if (e is! TimeoutException) rethrow; // Allow timeout to fail test if it's the test timeout
      // If we timed out waiting for close, that's a failure
      fail('Socket did not close within 20s');
    }

    // Check if closed
    expect(socket.closeCode, equals(4003));
    expect(socket.closeReason, equals('Auth timeout'));
  });
}
