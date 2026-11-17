import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:async/async.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';

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
    final tName = 'tenant_${random.nextInt(1 << 32)}';
    final createTenantRes = await http.post(
      Uri.parse('$httpUrl/api/admin/tenants'),
      headers: {
        'Authorization': 'Bearer $superToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'tenantName': tName,
        'adminUsername': 'admin_${random.nextInt(1 << 32)}',
        'adminPassword': 'password',
      }),
    );
    if (createTenantRes.statusCode != 200) {
      throw Exception('Create tenant failed');
    }
    final String effectiveTenantId = jsonDecode(
      createTenantRes.body,
    )['tenantId'];

    // 3. Create User
    final createUserRes = await http.post(
      Uri.parse('$httpUrl/api/users'),
      headers: {
        'Authorization': 'Bearer $superToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'username': username,
        'password': 'password',
        'tenantId': effectiveTenantId,
      }),
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
    String requiredTestSetting(String name) =>
        Platform.environment[name] ??
        (throw StateError(
          'Set $name for a disposable integration-test service',
        ));

    final portCompleter = Completer<int>();

    serverProcess = await Process.start(
      Platform.resolvedExecutable,
      ['bin/server.dart'],
      environment: {
        'LEGACY_GANTT_SYNC_PORT': '0',
        'JWT_SECRET': secret,
        'DB_HOST': Platform.environment['TEST_DB_HOST'] ?? '127.0.0.1',
        'DB_PORT': requiredTestSetting('TEST_DB_PORT'),
        'DB_USER': 'dart_user',
        'DB_PASS': requiredTestSetting('TEST_DB_PASS'),
        'DB_NAME': 'legacy_gantt',
        'DB_SSL_MODE': 'disable',
        'REDIS_HOST': '127.0.0.1',
        'REDIS_PORT': requiredTestSetting('TEST_REDIS_PORT'),
        'SUPERUSER_USERNAME': 'superuser',
        'SUPERUSER_PASSWORD': 'superuser',
      },
    );

    serverProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
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
    final actualPort = await portCompleter.future.timeout(
      const Duration(seconds: 30),
    );
    wsUrl = 'ws://localhost:$actualPort/ws';
    httpUrl = 'http://localhost:$actualPort';
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  test('Connects without token fails (403)', () async {
    try {
      await WebSocket.connect(wsUrl);
      fail('Should have failed to connect');
    } catch (e) {
      expect(e, isA<WebSocketException>());
      // Often the close code/reason isn't easily available on connect failure in Dart's WebSocket,
      // but the fact it failed is what we want.
    }
  });

  test('Successful Query Param Auth', () async {
    final username = 'auth_user_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username);
    final tenantId = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))),
    )['tenant_id'];

    // Append token to URL
    final authWsUrl = '$wsUrl?token=$token';
    final socket = await WebSocket.connect(authWsUrl);

    // No need to transmit 'auth'.
    // Expect AUTH_SUCCESS immediately
    bool authenticated = false;
    final queue = StreamQueue(socket);

    // Initial messages (likely AUTH_SUCCESS)
    while (await queue.hasNext) {
      // We might get broadcasts first if we are unlucky with timing, but AUTH_SUCCESS should be early.
      // Actually, server sends it immediately.
      final msg = await queue.next.timeout(const Duration(seconds: 5));
      final json = ProtobufMapper.toJson(
        ProtocolMessage.fromBuffer(msg as List<int>),
      );
      if (json['type'] == 'AUTH_SUCCESS') {
        authenticated = true;
        break;
      }
    }
    expect(authenticated, isTrue);

    // Now Subscribe
    socket.add(
      ProtobufMapper.toProtobuf({
        'type': 'subscribe',
        'channel': tenantId,
      }).writeToBuffer(),
    );

    // Expect SUBSCRIBE_SUCCESS
    bool subscribed = false;
    while (await queue.hasNext) {
      final msg = await queue.next.timeout(const Duration(seconds: 5));
      final json = ProtobufMapper.toJson(
        ProtocolMessage.fromBuffer(msg as List<int>),
      );
      if (json['type'] == 'SUBSCRIBE_SUCCESS') {
        expect(json['channel'], equals(tenantId));
        expect(json.containsKey('timestamp'), isFalse);
        expect(json.containsKey('actorId'), isFalse);
        subscribed = true;
        break;
      }
    }

    expect(subscribed, isTrue);
    await queue.cancel();
    await socket.close();
  });

  test('Fails on invalid token', () async {
    final authWsUrl = '$wsUrl?token=invalid_token_xyz';
    try {
      await WebSocket.connect(authWsUrl);
      fail('Should have failed to connect');
    } catch (e) {
      expect(e, isA<WebSocketException>());
    }
  });
}
