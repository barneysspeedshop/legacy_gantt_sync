import 'support/wire_protocol.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart' show Hlc;
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
    final superRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': 'superuser', 'password': 'superuser'}),
      headers: {'Content-Type': 'application/json'},
    );
    if (superRes.statusCode != 200) throw Exception('Superuser login failed');
    final superToken = jsonDecode(superRes.body)['accessToken'];

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
        'DB_PORT': Platform.environment['TEST_DB_PORT']!,
        'DB_USER': 'dart_user',
        'DB_PASS': Platform.environment['TEST_DB_PASS']!,
        'DB_NAME': 'legacy_gantt',
        'REDIS_HOST': '127.0.0.1',
        'REDIS_PORT': Platform.environment['TEST_REDIS_PORT']!,
        'SUPERUSER_USERNAME': 'superuser',
        'SUPERUSER_PASSWORD': 'superuser',
        'SOLVER_API_KEY': 'test_solver_key',
        'DB_SSL_MODE': 'disable',
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

    final actualPort = await portCompleter.future.timeout(
      const Duration(seconds: 120),
    );
    wsUrl = 'ws://localhost:$actualPort/ws';
    httpUrl = 'http://localhost:$actualPort';
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  test('Rejects single operation with future timestamp', () async {
    final username = 'user_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username);
    // final tenantId = ... (unused)
    // final String effectiveTenantId = jsonDecode(createTenantRes.body)['tenantId']; // Used in create user
    // In test 2:
    // final tenantId = jsonDecode(utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))))['tenant_id'];
    // It IS used in test 1 and 2 logic!
    // The lint complained about line 95.
    // Line 95 is inside `test('Rejects single operation...')`.
    // final tenantId = jsonDecode(...);
    // It is NOT used in that test. I can remove it.

    final socket = await WebSocket.connect('$wsUrl?token=$token');
    final queue = StreamQueue(socket);

    // Consume auth/subscribe success headers if any (usually just AUTH_SUCCESS)
    // We initiate subscribe to ensure we are in the channel? No, handlers don't enforce subscription to WRITE, but to READ.
    // However, to receive the ERROR frame, we just need to be connected.

    var authed = false;
    while (await queue.hasNext.timeout(const Duration(seconds: 5))) {
      final msg = await queue.next.timeout(const Duration(seconds: 5));
      final json = decodeMessage(msg);
      if (json['type'] == 'AUTH_SUCCESS') {
        authed = true;
        break;
      }
    }
    expect(authed, isTrue);

    // Send FUTURE op
    final futureTime =
        DateTime.now().millisecondsSinceEpoch + 70000; // 70s in future
    socket.add(
      encodeMessage({
        'type': 'INSERT_TASK',
        'timestamp': futureTime,
        'data': {'id': 'test-skew', 'name': 'Future Task'},
      }),
    );

    // Expect ERROR frame
    var errorReceived = false;
    try {
      while (await queue.hasNext.timeout(const Duration(seconds: 5))) {
        final msg = await queue.next.timeout(const Duration(seconds: 5));
        final json = decodeMessage(msg);
        // Server sends code: INVALID_TIMESTAMP and message: CLOCK_SKEW: ...
        if (json['type'] == 'ERROR' &&
            (json['error'] as String).contains('INVALID_TIMESTAMP') &&
            (json['error'] as String).contains('CLOCK_SKEW')) {
          errorReceived = true;
          break;
        }
      }
    } catch (_) {} // Timeout expected if no error

    expect(errorReceived, isTrue, reason: 'Should receive CLOCK_SKEW error');
    await queue.cancel();
    await socket.close();
  });

  test('Rejects single operation with future HLC timestamp', () async {
    final username = 'user_hlc_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username);

    final socket = await WebSocket.connect('$wsUrl?token=$token');
    final queue = StreamQueue(socket);

    // Consume auth/subscribe success
    await queue.next;

    // Send FUTURE HLC op
    final futureTime = DateTime.now().millisecondsSinceEpoch + 70000;
    final futureHlc =
        '${DateTime.fromMillisecondsSinceEpoch(futureTime, isUtc: true).toIso8601String()}-0000-node1';

    socket.add(
      encodeMessage({
        'type': 'INSERT_TASK',
        'timestamp': futureHlc,
        'data': {'id': 'test-hlc-skew', 'name': 'Future HLC Task'},
      }),
    );

    // Expect ERROR frame
    var errorReceived = false;
    try {
      while (await queue.hasNext.timeout(const Duration(seconds: 5))) {
        final msg = await queue.next.timeout(const Duration(seconds: 5));
        final json = decodeMessage(msg);
        if (json['type'] == 'ERROR' &&
            (json['error'] as String).contains('INVALID_TIMESTAMP') &&
            (json['error'] as String).contains('CLOCK_SKEW')) {
          errorReceived = true;
          break;
        }
      }
    } catch (_) {}

    expect(
      errorReceived,
      isTrue,
      reason: 'Should receive CLOCK_SKEW error for HLC',
    );
    await queue.cancel();
    await socket.close();
  });

  test('Accepts single operation with valid timestamp', () async {
    final username = 'user_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username);
    final tenantId = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))),
    )['tenant_id'];

    final socket = await WebSocket.connect('$wsUrl?token=$token');
    final queue = StreamQueue(socket);

    // Subscribe to hear our own echo
    socket.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    // Check auth/subscribe
    await queue.next; // Auth Success
    // Wait for subscribe success
    while (await queue.hasNext.timeout(const Duration(seconds: 5))) {
      final msg = await queue.next;
      final json = decodeMessage(msg);
      if (json['type'] == 'SUBSCRIBE_SUCCESS') break;
    }

    final observer = await WebSocket.connect('$wsUrl?token=$token');
    final observerQueue = StreamQueue(observer);
    observer.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));
    while (true) {
      final frame = decodeMessage(
        await observerQueue.next.timeout(const Duration(seconds: 5)),
      );
      if (frame['type'] == 'SUBSCRIBE_SUCCESS') break;
    }

    // Construct valid HLC
    final hlcParam = Hlc.fromDate(DateTime.now(), 'nodeTest').toString();

    socket.add(
      encodeMessage({
        'type': 'INSERT_TASK',
        'timestamp': hlcParam,
        'data': {'id': 'test-valid', 'name': 'Valid Task'},
      }),
    );

    // Expect Echo
    var echoReceived = false;
    try {
      while (await observerQueue.hasNext.timeout(const Duration(seconds: 5))) {
        final msg = await observerQueue.next.timeout(
          const Duration(seconds: 5),
        );
        final json = decodeMessage(msg);

        if (json['type'] == 'ERROR') {
          fail(
            'Received error response: ${json['message']} Code: ${json['code']}',
          );
        }

        if (json['type'] == 'INSERT_TASK' &&
            json['data']['id'] == 'test-valid') {
          echoReceived = true;
          expect(json['timestamp'], hlcParam);
          expect(json['data']['lastUpdated'], json['timestamp']);
          break;
        }
      }
    } catch (e) {
      if (e is TestFailure) rethrow; // Propagate assert failures
      // Ignore timeout logic for now, but fail if loop finished without echo
    }

    expect(
      echoReceived,
      isTrue,
      reason: 'Did not receive echo for valid operation',
    );
    await observerQueue.cancel();
    await observer.close();
    await queue.cancel();
    await socket.close();
  });
}
