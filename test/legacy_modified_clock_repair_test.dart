import 'dart:async';
import 'dart:io';

import 'package:legacy_gantt_sync/server/services/legacy_modified_clock_repair.dart';
import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart' as pg;
import 'package:test/test.dart';

void main() {
  test(
    'startup repairs legacy ISO bookkeeping clocks without changing data or tenant policies',
    () async {
      final environment = Platform.environment;
      final port = int.parse(environment['TEST_DB_PORT']!);
      final password = environment['TEST_DB_PASS']!;
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final databaseName = 'gantt_clock_repair_$suffix';
      final role = 'gantt_repair_$suffix';
      final admin = await Connection.open(
        Endpoint(
          host: '127.0.0.1',
          port: port,
          database: 'postgres',
          username: 'dart_user',
          password: password,
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      Connection? database;
      var roleCreated = false;
      try {
        await admin.execute('CREATE DATABASE $databaseName');
        database = await Connection.open(
          Endpoint(
            host: '127.0.0.1',
            port: port,
            database: databaseName,
            username: 'dart_user',
            password: password,
          ),
          settings: const ConnectionSettings(sslMode: SslMode.disable),
        );
        await database.execute('CREATE SCHEMA auth');
        await database.execute(
          'CREATE TABLE auth.tenants (id TEXT PRIMARY KEY)',
        );
        await database.execute(
          "INSERT INTO auth.tenants VALUES ('tenant-a'), ('tenant-b')",
        );
        Future<void> restart() async {
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
          final output = process.stdout
              .transform(systemEncoding.decoder)
              .join();
          final errors = process.stderr
              .transform(systemEncoding.decoder)
              .join();
          try {
            expect(
              await process.exitCode.timeout(const Duration(seconds: 15)),
              0,
              reason: await errors,
            );
            expect(await output, contains('CRDT_RESTART_READY'));
          } finally {
            process.kill();
          }
        }

        await restart();
        final date = DateTime.now().toUtc();
        final clocks = {
          'legacy-a': pg.Hlc(date, 7, 'legacy-a').toString(),
          'legacy-b': pg.Hlc(
            date.add(const Duration(milliseconds: 1)),
            31,
            'legacy-b',
          ).toString(),
          'valid': pg.Hlc(
            date.subtract(const Duration(seconds: 1)),
            5,
            'valid-node',
          ).toString(),
        };
        for (final entry in clocks.entries) {
          final clock = pg.Hlc.parse(entry.value);
          await database.execute(
            Sql.named('''
          INSERT INTO tasks (id, tenant_id, name, last_updated, hlc, node_id, modified, is_deleted)
          VALUES (@id, @tenant, @name, @clock, @clock, @node, @modified, 0)
        '''),
            parameters: {
              'id': entry.key,
              'tenant': entry.key == 'legacy-b' ? 'tenant-b' : 'tenant-a',
              'name': 'Preserve ${entry.key}',
              'clock': entry.value,
              'node': clock.nodeId,
              'modified': entry.key == 'valid'
                  ? entry.value
                  : clock.dateTime.toIso8601String(),
            },
          );
        }
        final before = await database.execute(
          'SELECT id, tenant_id, name, last_updated, hlc, node_id FROM tasks ORDER BY id',
        );
        await expectLater(
          pg.PostgresCrdt.open(
            databaseName,
            host: '127.0.0.1',
            port: port,
            username: 'dart_user',
            password: password,
            sslMode: SslMode.disable,
          ),
          throwsA(anything),
        );
        await restart();
        final repaired = await database.execute(
          'SELECT id, modified FROM tasks ORDER BY id',
        );
        expect({for (final row in repaired) row[0]: row[1]}, clocks);
        final after = await database.execute(
          'SELECT id, tenant_id, name, last_updated, hlc, node_id FROM tasks ORDER BY id',
        );
        expect(
          after.map((row) => row.toList()).toList(),
          before.map((row) => row.toList()).toList(),
        );
        expect(await repairLegacyModifiedClocks(database), 0);
        final policies = await database.execute(
          "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'public.tasks'::regclass",
        );
        expect(policies.single.toList(), [true, true]);

        // Exercise the same migration through FORCE RLS under a non-bypass role.
        for (final id in ['legacy-a', 'legacy-b']) {
          await database.execute(
            Sql.named('UPDATE tasks SET modified = @clock WHERE id = @id'),
            parameters: {
              'id': id,
              'clock': pg.Hlc.parse(clocks[id]!).dateTime.toIso8601String(),
            },
          );
        }
        await admin.execute(
          'CREATE ROLE $role NOLOGIN NOSUPERUSER NOBYPASSRLS',
        );
        roleCreated = true;
        await database.execute('GRANT USAGE ON SCHEMA public, auth TO $role');
        await database.execute(
          'GRANT SELECT ON auth.tenants, public.project_metadata, public.tasks TO $role',
        );
        await database.execute(
          'GRANT UPDATE (modified) ON public.tasks TO $role',
        );
        await database.execute('SET ROLE $role');
        try {
          expect(await repairLegacyModifiedClocks(database), 2);
        } finally {
          await database.execute('RESET ROLE');
        }
        expect({
          for (final row in await database.execute(
            'SELECT id, modified FROM tasks',
          ))
            row[0]: row[1],
        }, clocks);
        expect(await repairLegacyModifiedClocks(database), 0);
      } finally {
        await database?.close();
        await admin.execute(
          Sql.named(
            'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = @name',
          ),
          parameters: {'name': databaseName},
        );
        await admin.execute('DROP DATABASE IF EXISTS $databaseName');
        if (roleCreated) await admin.execute('DROP ROLE $role');
        await admin.close();
      }
    },
    skip: Platform.environment['TEST_DB_PORT'] == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
