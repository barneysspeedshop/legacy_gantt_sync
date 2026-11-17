import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:config/api_service.dart';
import 'package:config/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NetworkHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('binary subscriptions and updates survive reconnect', () {
    return HttpOverrides.runWithHttpOverrides(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      final firstSubscriptions = Completer<void>();
      final reconnectedSubscriptions = Completer<void>();
      server.listen((request) async {
        if (request.uri.path == '/auth/login') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'accessToken': 'test-only-token'}),
          );
          await request.response.close();
          return;
        }
        expect(request.uri.path, '/ws');
        expect(request.uri.queryParameters['token'], 'test-only-token');
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        final connected = sockets.length == 1
            ? firstSubscriptions
            : reconnectedSubscriptions;
        final channels = <String>{};
        socket.listen((frame) {
          expect(frame, isA<List<int>>());
          final message = ProtobufMapper.toJson(
            ProtocolMessage.fromBuffer(frame as List<int>),
          );
          expect(message['type'], 'subscribe');
          channels.add(message['channel'] as String);
          if (channels.length == 2 && !connected.isCompleted) {
            expect(channels, {'admin_updates', 'tenant_users_test-tenant'});
            connected.complete();
          }
        });
      });
      final api = ApiService('http://127.0.0.1:${server.port}', prefs);
      expect(await api.login('operator', 'test-only-password'), isTrue);
      final service = WebSocketService(api);
      addTearDown(service.dispose);
      service.subscribeToAdminUpdates();
      await service.connect();
      service.subscribeToTenantUsers('test-tenant');
      await firstSubscriptions.future.timeout(const Duration(seconds: 5));

      Future<void> verifyUpdates(WebSocket socket) async {
        final adminUpdate = expectLater(service.adminUpdates, emits(null));
        final userUpdate = expectLater(service.userUpdates, emits(null));
        socket.add(
          ProtobufMapper.toProtobuf({
            'type': 'TENANT_LIST_UPDATE',
          }).writeToBuffer(),
        );
        socket.add(
          ProtobufMapper.toProtobuf({
            'type': 'USER_LIST_UPDATE',
          }).writeToBuffer(),
        );
        await Future.wait([
          adminUpdate,
          userUpdate,
        ]).timeout(const Duration(seconds: 5));
      }

      await verifyUpdates(sockets.first);
      await sockets.first.close();
      await reconnectedSubscriptions.future.timeout(const Duration(seconds: 5));
      expect(sockets, hasLength(2));
      await verifyUpdates(sockets.last);
    }, NetworkHttpOverrides());
  });
}
