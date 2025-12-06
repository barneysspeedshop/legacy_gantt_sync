import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:async/async.dart';

void main() {
  Process? serverProcess;
  final port = 8082; // Different port for this test suite
  final url = 'ws://localhost:$port/ws';
  final secret = 'test_secret_key';

  String generateToken(String userId) {
    final jwt = JWT({'sub': userId});
    return jwt.sign(SecretKey(secret));
  }

  setUpAll(() async {
    serverProcess = await Process.start('dart', ['bin/server.dart'], environment: {'PORT': port.toString(), 'JWT_SECRET': secret});

    // Wait for server to start
    await Future.delayed(Duration(seconds: 2));

    serverProcess!.stdout.transform(utf8.decoder).listen((line) => print('[Server Out] $line'));
    serverProcess!.stderr.transform(utf8.decoder).listen((line) => print('[Server Err] $line'));
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  test('Rejects unauthorized clients', () async {
    expect(WebSocket.connect(url), throwsA(isA<WebSocketException>()));
  });

  test('Rejects invalid token', () async {
    expect(WebSocket.connect(url, headers: {'Authorization': 'Bearer invalid_token'}), throwsA(isA<WebSocketException>()));
  });

  test('Server broadcasts messages to other clients', () async {
    final token = generateToken('userA');
    final headers = {'Authorization': 'Bearer $token'};
    final clientA = IOWebSocketChannel.connect(url, headers: headers);
    final clientB = IOWebSocketChannel.connect(url, headers: headers);

    // Wait for connection
    await Future.delayed(Duration(milliseconds: 100));

    final message = {
      'type': 'UPDATE_TASK',
      'data': {'id': '100', 'name': 'Task 100'},
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'actorId': 'UserA',
    };

    final bQueue = StreamQueue(clientB.stream);

    clientA.sink.add(jsonEncode(message));

    // Client B should receive it
    bool found = false;
    int checks = 0;
    while (await bQueue.hasNext && checks < 5) {
      checks++;
      final event = await bQueue.next.timeout(Duration(seconds: 2));
      final decoded = jsonDecode(event as String);

      if (decoded['type'] == 'UPDATE_TASK' && decoded['data']['id'] == '100') {
        expect(decoded['actorId'], equals('UserA'));
        found = true;
        break;
      }
    }

    expect(found, isTrue);

    await clientA.sink.close();
    await clientB.sink.close();
  });

  test('New client receives history', () async {
    final token = generateToken('userHistory');
    final headers = {'Authorization': 'Bearer $token'};
    final clientA = IOWebSocketChannel.connect(url, headers: headers);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final message = {
      'type': 'UPDATE_TASK',
      'data': {'id': 'history_$timestamp', 'name': 'History Task'},
      'timestamp': timestamp,
      'actorId': 'UserHistory',
    };

    clientA.sink.add(jsonEncode(message));
    await Future.delayed(Duration(milliseconds: 200));

    // New client connects
    final clientB = IOWebSocketChannel.connect(url, headers: headers);
    final bQueue = StreamQueue(clientB.stream);

    // Should find the message in history
    bool found = false;
    try {
      while (await bQueue.hasNext) {
        final event = await bQueue.next.timeout(Duration(seconds: 2));
        final decoded = jsonDecode(event as String);
        if (decoded['data']['id'] == 'history_$timestamp') {
          found = true;
          break;
        }
      }
    } catch (e) {
      // Timeout
    }

    expect(found, isTrue);
    await clientB.sink.close();
    await clientA.sink.close();
  });
}
