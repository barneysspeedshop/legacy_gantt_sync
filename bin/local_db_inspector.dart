import 'dart:io';

import 'package:legacy_gantt_sync/local_inspector/inspector_auth_middleware.dart';
import 'package:legacy_gantt_sync/local_inspector/inspector_handler.dart';
import 'package:legacy_gantt_sync/local_inspector/inspector_service.dart';
import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

Future<void> main(List<String> args) async {
  final jwtSecret = Platform.environment['JWT_SECRET'];
  final localToken = Platform.environment['LOCAL_INSPECTOR_TOKEN'];
  if (jwtSecret == null || jwtSecret.isEmpty) {
    stderr.writeln('Missing JWT_SECRET environment variable');
    exitCode = 1;
    return;
  }
  if (localToken == null || localToken.isEmpty) {
    stderr.writeln('Missing LOCAL_INSPECTOR_TOKEN environment variable');
    exitCode = 1;
    return;
  }

  final port =
      int.tryParse(Platform.environment['LOCAL_INSPECTOR_PORT'] ?? '8787') ??
      8787;

  Future<Connection> openConnection() => Connection.open(
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
    settings: ConnectionSettings(sslMode: _sslMode()),
  );

  final database = InspectorDatabase(openConnection);
  final authService = AuthService(openConnection, jwtSecret);
  final apiRouter = InspectorHandler(database).router;
  final app = Router();
  app.get('/health', (Request request) => Response.ok('OK'));
  app.get('/api/local/v1/health', (Request request) => Response.ok('OK'));
  app.mount(
    '/api/local/v1/',
    const Pipeline()
        .addMiddleware(localInspectorCors())
        .addMiddleware(
          localInspectorAuth(
            jwtSecret: jwtSecret,
            localToken: localToken,
            authService: authService,
          ),
        )
        .addHandler(apiRouter.call),
  );

  final server = await shelf_io.serve(
    app.call,
    InternetAddress.loopbackIPv4,
    port,
  );
  JsonLogger.info('LOCAL_INSPECTOR_START', {
    'host': server.address.host,
    'port': server.port,
  });

  Future<void> shutdown() async {
    await server.close(force: true);
    await database.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  ProcessSignal.sigterm.watch().listen((_) => shutdown());
}

SslMode _sslMode() {
  final value = Platform.environment['DB_SSL_MODE']?.toLowerCase();
  return value == 'disable' ? SslMode.disable : SslMode.require;
}
