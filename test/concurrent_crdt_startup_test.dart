import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  test(
    'concurrent cold startups serialize schema creation across server processes',
    () async {
      final environment = Platform.environment;
      final port = int.parse(environment['TEST_DB_PORT']!);
      final password = environment['TEST_DB_PASS']!;
      final databaseName =
          'gantt_cold_start_${DateTime.now().microsecondsSinceEpoch}';
      Future<Connection> connect(String database) => Connection.open(
        Endpoint(
          host: '127.0.0.1',
          port: port,
          database: database,
          username: 'dart_user',
          password: password,
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      final admin = await connect('postgres');
      Connection? guard;
      final processes = <Process>[];
      final results = <Future<(int, String, String)>>[];
      try {
        await admin.execute('CREATE DATABASE $databaseName');
        guard = await connect(databaseName);
        await guard.execute(
          "SELECT pg_advisory_lock(hashtext('legacy_gantt_sync'), hashtext('schema_init'))",
        );
        for (var index = 0; index < 2; index++) {
          final process = await Process.start(
            Platform.resolvedExecutable,
            ['run', 'test/support/crdt_restart_probe.dart'],
            environment: {
              ...environment,
              'DB_HOST': '127.0.0.1',
              'DB_PORT': '$port',
              'DB_NAME': databaseName,
              'DB_USER': 'dart_user',
              'DB_PASS': password,
              'DB_SSL_MODE': 'disable',
            },
          );
          processes.add(process);
          final output = process.stdout.transform(utf8.decoder).join();
          final errors = process.stderr.transform(utf8.decoder).join();
          results.add(
            (() async =>
                (await process.exitCode, await output, await errors))(),
          );
        }
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        var waiting = 0;
        while (DateTime.now().isBefore(deadline)) {
          final rows = await admin.execute(
            Sql.named('''
            SELECT COUNT(*) FROM pg_stat_activity
            WHERE datname = @database AND wait_event = 'advisory'
          '''),
            parameters: {'database': databaseName},
          );
          waiting = rows.single[0]! as int;
          if (waiting == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(
          waiting,
          2,
          reason:
              'Both startup processes must wait on the database schema guard',
        );
        expect(
          (await guard.execute("SELECT to_regclass('public.tasks')")).single[0],
          isNull,
          reason:
              'Neither process may create schema before acquiring the guard',
        );
        await guard.execute(
          "SELECT pg_advisory_unlock(hashtext('legacy_gantt_sync'), hashtext('schema_init'))",
        );
        final completed = await Future.wait(
          results,
        ).timeout(const Duration(seconds: 20));
        for (final (exitCode, output, errors) in completed) {
          expect(exitCode, 0, reason: errors);
          expect(output, contains('CRDT_RESTART_READY'));
          expect(output, isNot(contains('RETRY_OPERATION_FAILED')));
          expect(output, isNot(contains('DB_INIT_FAIL')));
        }
        final tables = await guard.execute('''
          SELECT table_name FROM information_schema.tables
          WHERE table_schema = 'public' AND table_name IN ('tasks', 'resources', 'dependencies', 'project_metadata')
          ORDER BY table_name
        ''');
        expect(tables.map((row) => row[0]).toList(), [
          'dependencies',
          'project_metadata',
          'resources',
          'tasks',
        ]);
        final policies = await guard.execute('''
          SELECT tablename FROM pg_policies WHERE schemaname = 'public' AND policyname = 'tenant_isolation'
          ORDER BY tablename
        ''');
        expect(policies.map((row) => row[0]).toList(), [
          'dependencies',
          'resources',
          'tasks',
        ]);
      } finally {
        for (final process in processes) {
          process.kill();
        }
        await guard?.close();
        await admin.execute(
          Sql.named('''
          SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = @database AND pid <> pg_backend_pid()
        '''),
          parameters: {'database': databaseName},
        );
        await admin.execute('DROP DATABASE IF EXISTS $databaseName');
        await admin.close();
      }
    },
    skip: Platform.environment['TEST_DB_PORT'] == null,
    timeout: const Timeout(Duration(seconds: 50)),
  );
  test(
    'two full servers become HTTP ready against the same cold database',
    () async {
      final environment = Platform.environment;
      final port = int.parse(environment['TEST_DB_PORT']!);
      final databaseName =
          'gantt_server_cold_${DateTime.now().microsecondsSinceEpoch}';
      final admin = await Connection.open(
        Endpoint(
          host: '127.0.0.1',
          port: port,
          database: 'postgres',
          username: 'dart_user',
          password: environment['TEST_DB_PASS'],
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      final processes = <Process>[];
      final ready = <Future<int>>[];
      final output = StringBuffer();
      final errors = StringBuffer();
      final http = HttpClient();
      try {
        await admin.execute('CREATE DATABASE $databaseName');
        for (var index = 0; index < 2; index++) {
          final process = await Process.start(
            Platform.resolvedExecutable,
            ['bin/server.dart'],
            environment: {
              ...environment,
              'DB_HOST': '127.0.0.1',
              'DB_PORT': '$port',
              'DB_NAME': databaseName,
              'DB_USER': 'dart_user',
              'DB_PASS': environment['TEST_DB_PASS']!,
              'DB_SSL_MODE': 'disable',
              'REDIS_HOST': '127.0.0.1',
              'REDIS_PORT': environment['TEST_REDIS_PORT']!,
              'LEGACY_GANTT_SYNC_PORT': '0',
              'JWT_SECRET': 'cold-start-fixture-secret',
            },
          );
          processes.add(process);
          final started = Completer<int>();
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                output.writeln(line);
                if (line.contains('SERVER_START') && !started.isCompleted) {
                  final event = jsonDecode(line) as Map<String, dynamic>;
                  started.complete((event['data'] as Map)['port'] as int);
                }
              });
          process.stderr.transform(utf8.decoder).listen(errors.write);
          ready.add(
            Future.any([
              started.future,
              process.exitCode.then<int>(
                (code) => throw StateError('Server exited with $code: $errors'),
              ),
            ]),
          );
        }
        final ports = await Future.wait(
          ready,
        ).timeout(const Duration(seconds: 20));
        expect(ports.toSet(), hasLength(2));
        for (final boundPort in ports) {
          final request = await http.getUrl(
            Uri.parse('http://127.0.0.1:$boundPort/health'),
          );
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);
          expect(await response.transform(utf8.decoder).join(), 'OK');
        }
        expect(output.toString(), isNot(contains('DB_INIT_FAIL')));
        expect(
          output.toString(),
          isNot(contains('AUTH_DB_RETRY')),
          reason:
              'Cold initialization must serialize schema creation rather than retry catalog races',
        );
        expect(errors.toString(), isEmpty);
      } finally {
        http.close(force: true);
        for (final process in processes) {
          process.kill();
        }
        await Future.wait(
          processes.map((process) => process.exitCode),
        ).timeout(const Duration(seconds: 5));
        await admin.execute(
          Sql.named('''
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = @database AND pid <> pg_backend_pid()
      '''),
          parameters: {'database': databaseName},
        );
        await admin.execute('DROP DATABASE IF EXISTS $databaseName');
        await admin.close();
      }
    },
    skip:
        Platform.environment['TEST_DB_PORT'] == null ||
        Platform.environment['TEST_REDIS_PORT'] == null,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
