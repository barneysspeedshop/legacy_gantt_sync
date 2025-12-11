import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  Process? serverA;
  Process? serverB;
  late int portA;
  late int portB;
  late String hostA;

  final dbConfig = {
    'DB_HOST': 'localhost',
    'DB_PORT': '5432',
    'DB_USER': 'dart_user',
    'DB_PASS': 'dart_password',
    'DB_NAME': 'legacy_gantt',
    'JWT_SECRET': 'test_secret',
    'SUPERUSER_USERNAME': 'redis_test_super',
    'SUPERUSER_PASSWORD': 'redis_test_pass',
  };

  // Helper to start a server instance
  Future<Process> startServer(Completer<int> portCompleter) async {
    final process = await Process.start(
      'dart',
      ['bin/server.dart'],
      environment: {'LEGACY_GANTT_SYNC_PORT': '0', ...dbConfig},
    );

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          print('[${process.pid} STDOUT] $line');
          if (!portCompleter.isCompleted && line.contains('SERVER_START')) {
            try {
              final json = jsonDecode(line);
              if (json['event'] == 'SERVER_START') {
                portCompleter.complete(json['data']['port'] as int);
              }
            } catch (_) {}
          }
        });
    process.stderr
        .transform(utf8.decoder)
        .listen((line) => print('[${process.pid} STDERR] $line'));

    return process;
  }

  setUpAll(() async {
    final portACompleter = Completer<int>();
    final portBCompleter = Completer<int>();

    serverA = await startServer(portACompleter);
    serverB = await startServer(portBCompleter);

    portA = await portACompleter.future.timeout(const Duration(seconds: 10));
    portB = await portBCompleter.future.timeout(const Duration(seconds: 10));

    hostA = 'http://localhost:$portA';

    print('Server A started on port $portA');
    print('Server B started on port $portB');
  });

  tearDownAll(() {
    serverA?.kill();
    serverB?.kill();
  });

  test('Redis Sync: Message propagates from Server A to Server B', () async {
    // 1. Setup Tenant and User via Server A (DB is shared)
    // Login Superuser
    final loginRes = await http.post(
      Uri.parse('$hostA/auth/login'),
      body: jsonEncode({
        'username': 'redis_test_super',
        'password': 'redis_test_pass',
      }),
    );
    expect(loginRes.statusCode, 200, reason: 'Superuser login failed');
    final superToken = jsonDecode(loginRes.body)['accessToken'];

    // Create Tenant
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tenantName = 'RedisTenant_$timestamp';
    final adminUsername = 'admin_$timestamp';
    final regRes = await http.post(
      Uri.parse('$hostA/api/admin/tenants'),
      headers: {'Authorization': 'Bearer $superToken'},
      body: jsonEncode({
        'tenantName': tenantName,
        'adminUsername': adminUsername,
        'adminPassword': 'password',
      }),
    );
    expect(regRes.statusCode, 200, reason: 'Tenant creation failed');
    final tenantId = jsonDecode(regRes.body)['tenantId'];

    // Create User
    final username = 'userA_$timestamp';
    final userRes = await http.post(
      Uri.parse('$hostA/api/users'),
      headers: {'Authorization': 'Bearer $superToken'},
      body: jsonEncode({
        'username': username,
        'password': 'password',
        'tenantId': tenantId,
      }),
    );
    expect(userRes.statusCode, 200, reason: 'User creation failed');

    // Login as User to get token
    final userLogin = await http.post(
      Uri.parse('$hostA/auth/login'),
      body: jsonEncode({'username': username, 'password': 'password'}),
    );
    final userToken = jsonDecode(userLogin.body)['accessToken'];

    // 2. Connect Client A to Server A
    final wsUrlA = 'ws://localhost:$portA/ws?token=$userToken';
    final channelA = IOWebSocketChannel.connect(wsUrlA);
    await channelA.ready;

    // 3. Connect Client B to Server B (same user/tenant, different server)
    final wsUrlB = 'ws://localhost:$portB/ws?token=$userToken';
    final channelB = IOWebSocketChannel.connect(wsUrlB);
    await channelB.ready;

    // 4. Subscribe both
    // Server expects { 'type': 'subscribe', 'channel': tenantId }
    final subscribeMsg = jsonEncode({'type': 'subscribe', 'channel': tenantId});
    channelA.sink.add(subscribeMsg);
    channelB.sink.add(subscribeMsg);

    // Wait for subscriptions to settle
    await Future.delayed(const Duration(milliseconds: 500));

    // 5. Send Operation from A
    // Server expects { 'type': '...', 'data': ... }
    final opId = 'op_${DateTime.now().millisecondsSinceEpoch}';
    final opMsg = jsonEncode({
      'type': 'INSERT_TASK', // Using a concrete type the server handles
      'data': {
        'messageId': opId,
        'data': {
          'id': 'task1',
          'name': 'Synced Task',
          'start_date': 1735689600000, // 2025-01-01
          'end_date': 1735776000000,
        },
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    channelA.sink.add(opMsg);

    // 6. Expect Operation on B
    // Server logic processes the operation and broadcasts it.
    // We expect B to receive an INSERT_TASK message.
    try {
      await channelB.stream
          .firstWhere((message) {
            // print('[B recv] $message');
            final json = jsonDecode(message);
            // The server might wrap it or pass it through.
            // Server logic line 628: broadcast message is sent as JSON.
            // It replays the original message structure mostly.
            // But let's check broadly for the data we sent.
            if (json['type'] == 'INSERT_TASK') {
              final data = json['data'];
              if (data is Map && data.containsKey('data')) {
                return data['data']['id'] == 'task1';
              }
              // Or maybe it's flat?
              return data['id'] == 'task1';
            }
            return false;
          })
          .timeout(const Duration(seconds: 5));
      print('✅ Client B received operation from Client A via Redis');
    } catch (e) {
      fail('Client B did not receive the operation from Client A: $e');
    }

    channelA.sink.close();
    channelB.sink.close();
  });
}
