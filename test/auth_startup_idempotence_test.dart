import 'dart:io';

import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  group('auth schema startup', () {
    late Connection admin;
    late Connection database;
    late String databaseName;
    final connections = <Connection>[];
    Future<Connection> connect(String name) => Connection.open(
      Endpoint(
        host: '127.0.0.1',
        port: int.parse(Platform.environment['TEST_DB_PORT']!),
        database: name,
        username: 'dart_user',
        password: Platform.environment['TEST_DB_PASS'],
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    AuthService service() => AuthService(() async {
      final connection = await connect(databaseName);
      connections.add(connection);
      return connection;
    }, 'auth-startup-fixture-secret');
    setUp(() async {
      admin = await connect('postgres');
      databaseName =
          'gantt_auth_start_${DateTime.now().microsecondsSinceEpoch}';
      await admin.execute('CREATE DATABASE $databaseName');
      database = await connect(databaseName);
    });
    tearDown(() async {
      for (final connection in connections) {
        await connection.close();
      }
      connections.clear();
      await database.close();
      await admin.execute('DROP DATABASE $databaseName');
      await admin.close();
    });

    test(
      'a hashed refresh session survives reinitialization and another auth instance',
      () async {
        final first = service();
        final second = service();
        await first.init();
        await first.registerTenant(
          'Startup tenant',
          'startup-user',
          'fixture-password',
        );
        final session = await first.login('startup-user', 'fixture-password');
        final token = session['refreshToken']!;
        await Future.wait([first.init(), second.init()]);
        expect((await first.refresh(token))['accessToken'], isNotEmpty);
        expect((await second.refresh(token))['accessToken'], isNotEmpty);
        expect(
          (await database.execute(
            'SELECT COUNT(*) FROM auth.refresh_tokens',
          )).single[0],
          1,
        );
      },
    );

    test(
      'legacy unhashed refresh schema upgrades once and preserves subsequent sessions',
      () async {
        await database.execute('CREATE SCHEMA auth');
        await database.execute(
          'CREATE TABLE auth.refresh_tokens (id TEXT PRIMARY KEY, token TEXT)',
        );
        await database.execute(
          "INSERT INTO auth.refresh_tokens VALUES ('legacy', 'obsolete-fixture-value')",
        );
        final auth = service();
        await auth.init();
        final columns = await database.execute(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = 'auth' AND table_name = 'refresh_tokens'",
        );
        expect(columns.map((row) => row[0]), contains('token_hash'));
        expect(columns.map((row) => row[0]), isNot(contains('token')));
        expect(
          (await database.execute(
            'SELECT COUNT(*) FROM auth.refresh_tokens',
          )).single[0],
          0,
        );
        await auth.registerTenant(
          'Upgrade tenant',
          'upgrade-user',
          'fixture-password',
        );
        final session = await auth.login('upgrade-user', 'fixture-password');
        await auth.init();
        expect(
          (await auth.refresh(session['refreshToken']!))['accessToken'],
          isNotEmpty,
        );
        expect(
          (await database.execute(
            'SELECT COUNT(*) FROM auth.refresh_tokens',
          )).single[0],
          1,
        );
      },
    );
  }, skip: Platform.environment['TEST_DB_PORT'] == null);
}
