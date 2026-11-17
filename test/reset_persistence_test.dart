import 'support/wire_protocol.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:async/async.dart';

void main() {
  Process? serverProcess;
  final random = Random();
  late String wsUrl;
  late String httpUrl;
  final secret = 'test_secret_key';

  Future<String> registerAndLogin(String username, {String? tenantId}) async {
    final superRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': 'superuser', 'password': 'superuser'}),
      headers: {'Content-Type': 'application/json'},
    );
    final superToken = jsonDecode(superRes.body)['accessToken'];

    final tName = tenantId ?? 'tenant_${random.nextInt(1 << 32)}';
    final createTenantRes = await http.post(
      Uri.parse('$httpUrl/api/admin/tenants'),
      headers: {
        'Authorization': 'Bearer $superToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'tenantName': tName,
        'adminUsername': 'temp_admin_${random.nextInt(1 << 32)}',
        'adminPassword': 'password',
      }),
    );
    final String effectiveTenantId = jsonDecode(
      createTenantRes.body,
    )['tenantId'];

    await http.post(
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

    final loginRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': username, 'password': 'password'}),
      headers: {'Content-Type': 'application/json'},
    );

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
        'SOLVER_API_KEY': 'dummy_key',
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

    serverProcess!.stderr
        .transform(utf8.decoder)
        .listen((line) => print('[Server Err] $line'));

    try {
      final actualPort = await portCompleter.future.timeout(
        const Duration(seconds: 30),
      );
      wsUrl = 'ws://localhost:$actualPort/ws';
      httpUrl = 'http://localhost:$actualPort';
    } catch (e) {
      throw Exception('Failed to start test server: $e');
    }
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  test(
    'RESET_DATA is replayed to clients syncing from before the reset',
    () async {
      final tenantId = 'reset_persistence_${random.nextInt(1 << 32)}';
      final username = 'user_reset_p_${random.nextInt(1 << 32)}';
      final token = await registerAndLogin(username, tenantId: tenantId);

      final client1 = IOWebSocketChannel.connect(
        wsUrl,
        headers: {'Authorization': 'Bearer $token'},
      );
      client1.sink.add(
        encodeMessage({'type': 'subscribe', 'channel': tenantId}),
      );
      await client1.stream.firstWhere(
        (e) => decodeMessage(e)['type'] == 'SUBSCRIBE_SUCCESS',
      );

      // 1. Send RESET_DATA
      final resetTimestamp = DateTime.now().millisecondsSinceEpoch;
      client1.sink.add(
        encodeMessage({
          'type': 'RESET_DATA',
          'data': <String, dynamic>{},
          'timestamp': resetTimestamp,
          'actorId': username,
        }),
      );

      await Future.delayed(const Duration(milliseconds: 500));
      await client1.sink.close();

      // 2. Connect Client 2 with old timestamp (before reset)
      final client2 = IOWebSocketChannel.connect(
        wsUrl,
        headers: {'Authorization': 'Bearer $token'},
      );
      final queue = StreamQueue(client2.stream);

      // Simulate syncing from 1 hour ago
      final lastSynced = resetTimestamp - 3600000;
      client2.sink.add(
        encodeMessage({
          'type': 'subscribe',
          'channel': tenantId,
          'lastSyncedTimestamp': lastSynced,
        }),
      );

      bool foundReset = false;
      try {
        while (await queue.hasNext.timeout(const Duration(seconds: 3))) {
          final event = await queue.next.timeout(const Duration(seconds: 2));
          final msg = decodeMessage(event);
          if (msg['type'] == 'RESET_DATA') {
            // We expect the server to transmit the stored timestamp, which might be slightly different depending on clamping or if we used server time
            // But checking type is enough proof it was replayed
            foundReset = true;
            break;
          }
        }
      } catch (e) {
        // Timeout
      }

      expect(
        foundReset,
        isTrue,
        reason:
            'RESET_DATA should be replayed to client syncing from old state',
      );
      await queue.cancel();
      await client2.sink.close();
    },
  );
}
