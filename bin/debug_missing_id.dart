import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/io.dart';

void main() async {
  final wsUrl = 'ws://localhost:8080/ws';

  // Quick login to get token
  final httpClient = HttpClient();
  final loginReq = await httpClient.postUrl(Uri.parse('http://localhost:8080/auth/login'));
  loginReq.headers.contentType = ContentType.json;
  loginReq.write(jsonEncode({'username': 'patrick', 'password': 'password'}));
  final loginRes = await loginReq.close();
  final loginBody = await loginRes.transform(utf8.decoder).join();
  final token = jsonDecode(loginBody)['accessToken'];

  print('Got token: ${token.substring(0, 10)}...');

  final channel = IOWebSocketChannel.connect(wsUrl, headers: {'Authorization': 'Bearer $token'});

  // Subscribe first
  final tenantId = 'legacy';
  channel.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

  await Future.delayed(const Duration(milliseconds: 500));

  // Send valid payload to see logging
  print('Sending dependency message...');
  channel.sink.add(
    jsonEncode({
      'type': 'INSERT_DEPENDENCY',
      'data': {
        'data': {'predecessorTaskId': 't1', 'successorTaskId': 't2', 'type': 'finishToStart'},
      },
      'runtimeType': 'operation', // Required by freezed, supposedly client handles this
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'actorId': 'patrick',
    }),
  );

  await Future.delayed(const Duration(seconds: 1));
  await channel.sink.close();
  print('Done.');
}
