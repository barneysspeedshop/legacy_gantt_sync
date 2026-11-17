import 'dart:async';
import 'dart:io';

import 'package:legacy_gantt_sync/middleware/auth_middleware.dart';
import 'package:legacy_gantt_sync/middleware/request_logging_middleware.dart';
import 'package:legacy_gantt_sync/server/handlers/auth_handler.dart';
import 'package:legacy_gantt_sync/server/handlers/tenant_handler.dart';
import 'package:legacy_gantt_sync/server/handlers/user_handler.dart';
import 'package:legacy_gantt_sync/server/handlers/websocket_handler.dart';
import 'package:legacy_gantt_sync/server/middleware/cors_middleware.dart';
import 'package:legacy_gantt_sync/server/services/client_service.dart';
import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_sync/server/services/operation_service.dart';
import 'package:legacy_gantt_sync/server/services/pub_sub_service.dart';
import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:legacy_gantt_sync/services/solver_service.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:legacy_gantt_sync/utils/retry_utils.dart';
import 'package:legacy_gantt_sync/server/services/merkle_service.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

void main(List<String> args) async {
  final port = int.parse(
    Platform.environment['LEGACY_GANTT_SYNC_PORT'] ?? '8080',
  );
  final jwtSecret = Platform.environment['JWT_SECRET'];
  if (jwtSecret == null || jwtSecret.trim().isEmpty) {
    JsonLogger.error('CONFIG_ERROR', {
      'error': 'Missing JWT_SECRET environment variable',
    });
    exit(1);
  }

  Future<Connection> authConnectionFactory() {
    return retryForever(
      () => Connection.open(
        Endpoint(
          host: Platform.environment['DB_HOST'] ?? 'localhost',
          database: Platform.environment['DB_NAME'] ?? 'legacy_gantt',
          username:
              Platform.environment['DB_USER'] ??
              (throw ArgumentError('DB_USER is required')),
          password:
              Platform.environment['DB_PASS'] ??
              (throw ArgumentError('DB_PASS is required')),
          port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      ),
      description: 'Connect to Main DB',
      maxRetries: 10, // Fail fast-ish on startup so we don't zombie loop
    );
  }

  final authService = AuthService(authConnectionFactory, jwtSecret);
  await authService.init();

  final superUserUser = Platform.environment['SUPERUSER_USERNAME'];
  final superUserPass = Platform.environment['SUPERUSER_PASSWORD'];
  if (superUserUser != null && superUserPass != null) {
    try {
      await authService.ensureSuperuser(superUserUser, superUserPass);
    } catch (e) {
      JsonLogger.error('SEED_SUPERUSER_FAIL', {'error': e.toString()});
    }
  } else {
    JsonLogger.warn('SEED_SUPERUSER_SKIPPED', {
      'message': 'SUPERUSER_USERNAME/PASSWORD not set',
    });
  }

  // FFI Solver - no API key needed
  final solverService = SolverService();
  final crdtService = CrdtService();
  await crdtService.init();
  final operationService = OperationService(solverService);

  final pubSubService = PubSubService();
  final redisHost = Platform.environment['REDIS_HOST'] ?? 'localhost';
  final redisPort = int.parse(Platform.environment['REDIS_PORT'] ?? '6379');
  await pubSubService.init(redisHost, redisPort);

  final clientService = ClientService(pubSubService);
  clientService.startListening();

  final merkleService = MerkleService(crdtService);

  final authHandler = AuthHandler(authService);
  final tenantHandler = TenantHandler(
    authService,
    pubSubService,
    clientService,
  );
  final userHandler = UserHandler(authService, pubSubService, clientService);
  final webSocketHandler = WebSocketHandler(
    authService: authService,
    crdtService: crdtService,
    operationService: operationService,
    clientService: clientService,
    pubSubService: pubSubService,
    merkleService: merkleService,
  );

  final apiRouter = Router();
  apiRouter.mount('/', tenantHandler.router.call);
  apiRouter.mount('/', userHandler.router.call);

  final app = Router();

  app.post('/auth/login', authHandler.login);
  app.post('/auth/register', authHandler.register);

  app.mount(
    '/api/',
    const Pipeline()
        .addMiddleware(
          roleMiddleware(['tenant_admin', 'superuser']),
        ) // Default minimal protection
        .addHandler(apiRouter.call),
  );

  app.get('/ws', webSocketHandler.handleRequest);

  app.get('/health', (Request request) => Response.ok('OK'));

  final handler = const Pipeline()
      .addMiddleware(corsHeaders())
      .addMiddleware(requestLoggingMiddleware())
      .addMiddleware(authMiddleware(jwtSecret, authService))
      .addHandler(app.call);

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  JsonLogger.info('SERVER_START', {
    'host': server.address.host,
    'port': server.port,
  });
}
