import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:legacy_gantt_sync/middleware/auth_middleware.dart';
import 'package:legacy_gantt_sync/local_inspector/inspector_auth_middleware.dart';
import 'package:legacy_gantt_sync/middleware/request_logging_middleware.dart';
import 'package:legacy_gantt_sync/models/auth_models.dart';
import 'package:legacy_gantt_sync/server/handlers/auth_handler.dart';
import 'package:legacy_gantt_sync/server/handlers/tenant_handler.dart';
import 'package:legacy_gantt_sync/server/handlers/websocket_handler.dart';
import 'package:legacy_gantt_sync/server/services/client_service.dart';
import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_sync/server/services/merkle_service.dart';
import 'package:legacy_gantt_sync/server/services/operation_service.dart';
import 'package:legacy_gantt_sync/server/services/pub_sub_service.dart';
import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

class MockAuth extends Mock implements AuthService {}

class MockCrdt extends Mock implements CrdtService {}

class MockMerkle extends Mock implements MerkleService {}

class MockOperations extends Mock implements OperationService {}

void main() {
  late MockAuth auth;
  setUp(() => auth = MockAuth());

  test(
    'registration returns login tokens with no licensing dependency',
    () async {
      when(
        () => auth.registerTenant('Example', 'owner', 'test-password'),
      ).thenAnswer(
        (_) async => Tenant(id: 'tenant', name: 'Example', isActive: true),
      );
      when(() => auth.login('owner', 'test-password')).thenAnswer(
        (_) async => {
          'accessToken': 'test-access',
          'refreshToken': 'test-refresh',
        },
      );
      final response = await AuthHandler(auth).register(
        Request(
          'POST',
          Uri.parse('http://localhost/auth/register'),
          body: jsonEncode({
            'tenantName': 'Example',
            'username': 'owner',
            'password': 'test-password',
          }),
        ),
      );
      expect(response.statusCode, 200);
      expect(jsonDecode(await response.readAsString()), {
        'accessToken': 'test-access',
        'refreshToken': 'test-refresh',
      });
    },
  );

  test(
    'admin can create a tenant without a trial; normal users cannot',
    () async {
      when(
        () => auth.registerTenant('Example', 'owner', 'test-password'),
      ).thenAnswer(
        (_) async => Tenant(id: 'tenant', name: 'Example', isActive: true),
      );
      final pubsub = PubSubService();
      final handler = TenantHandler(
        auth,
        pubsub,
        ClientService(pubsub),
      ).router.call;
      Request request(String role) => Request(
        'POST',
        Uri.parse('http://localhost/admin/tenants'),
        context: {'auth.role': role},
        body: jsonEncode({
          'tenantName': 'Example',
          'adminUsername': 'owner',
          'adminPassword': 'test-password',
        }),
      );
      expect((await handler(request('user'))).statusCode, 403);
      final response = await handler(request('superuser'));
      expect(response.statusCode, 200);
      expect(jsonDecode(await response.readAsString()), {
        'tenantId': 'tenant',
        'message': 'Tenant registered successfully',
      });
    },
  );

  test(
    'inspector authentication preserves downstream handler failures',
    () async {
      when(() => auth.isUserActive('operator')).thenAnswer((_) async => true);
      when(() => auth.isTenantActive('system')).thenAnswer((_) async => true);
      final token = JWT({
        'sub': 'operator',
        'role': 'superuser',
        'tenant_id': 'system',
      }).sign(SecretKey('inspector-test-secret'));
      final failure = StateError('downstream failure');
      final handler = localInspectorAuth(
        jwtSecret: 'inspector-test-secret',
        localToken: 'inspector-test-token',
        authService: auth,
      )((_) => throw failure);
      await expectLater(
        handler(
          Request(
            'GET',
            Uri.parse('http://localhost/tables'),
            headers: {
              'Authorization': 'Bearer $token',
              'x-local-inspector-token': 'inspector-test-token',
            },
          ),
        ),
        throwsA(same(failure)),
      );
    },
  );

  test('request logs omit query tokens, authorization and referer', () async {
    final logs = <Map<String, dynamic>>[];
    final handler = const Pipeline()
        .addMiddleware(requestLoggingMiddleware(writeLog: logs.add))
        .addHandler((_) => Response.ok('OK'));
    final response = await handler(
      Request(
        'GET',
        Uri.parse('http://localhost/ws?token=sensitive-token&other=private'),
        headers: {
          'Authorization': 'Bearer sensitive-header',
          'Referer': 'http://localhost/?token=private-referrer',
        },
      ),
    );
    expect(response.statusCode, 200);
    expect(logs, [
      {'method': 'GET', 'path': 'ws', 'status': 200},
    ]);
  });

  test(
    'active authenticated tenant opens WebSocket without a license; revoked tenant is denied',
    () async {
      const secret = 'test-only-open-source-auth-secret';
      var active = true;
      when(() => auth.isUserActive('user')).thenAnswer((_) async => true);
      when(() => auth.isTenantActive('tenant')).thenAnswer((_) async => active);
      final pubsub = PubSubService();
      final clients = ClientService(pubsub);
      final ws = WebSocketHandler(
        authService: auth,
        crdtService: MockCrdt(),
        operationService: MockOperations(),
        clientService: clients,
        pubSubService: pubsub,
        merkleService: MockMerkle(),
      );
      final server = await shelf_io.serve(
        const Pipeline()
            .addMiddleware(authMiddleware(secret, auth))
            .addHandler(ws.handleRequest),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final token = JWT({
        'sub': 'user',
        'tenant_id': 'tenant',
        'role': 'user',
      }).sign(SecretKey(secret), expiresIn: const Duration(minutes: 1));
      final url = 'ws://127.0.0.1:${server.port}/ws?token=$token';
      final socket = await WebSocket.connect(url);
      final queue = StreamQueue(socket);
      final message = await queue.next.timeout(const Duration(seconds: 5));
      expect(
        ProtocolMessage.fromBuffer(message as List<int>).type,
        'AUTH_SUCCESS',
      );
      expect(clients.getActiveConnectionsCount('tenant'), 1);
      socket.add(
        ProtobufMapper.toProtobuf({
          'type': 'OPTIMIZE_SCHEDULE',
          'timestamp': Hlc.fromDate(DateTime.now(), 'test').toString(),
        }).writeToBuffer(),
      );
      final optimizationReply = ProtocolMessage.fromBuffer(
        await queue.next.timeout(const Duration(seconds: 5)) as List<int>,
      );
      expect(optimizationReply.type, 'ERROR');
      expect(
        optimizationReply.error,
        'Scheduling is experimental and not implemented',
      );
      await socket.close();
      await queue.cancel();
      active = false;
      await expectLater(
        WebSocket.connect(url),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:${server.port}/ws'),
        throwsA(isA<WebSocketException>()),
      );
    },
  );
}
