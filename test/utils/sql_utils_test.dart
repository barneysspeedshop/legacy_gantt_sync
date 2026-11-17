import 'package:test/test.dart';
import 'package:legacy_gantt_sync/server/utils/sql_utils.dart';

void main() {
  group('SqlUtils', () {
    test('buildUpsertQuery generates correct SQL for standard case', () {
      final sql = SqlUtils.buildUpsertQuery(
        table: 'users',
        columns: ['id', 'name', 'email'],
        conflictColumns: ['id'],
      );

      expect(
        sql,
        'INSERT INTO users (id, name, email) VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, email = EXCLUDED.email, is_deleted = 0, deleted_at = NULL',
      );
    });

    test('buildUpsertQuery excludes conflict columns from update', () {
      final sql = SqlUtils.buildUpsertQuery(
        table: 'tasks',
        columns: ['tenant_id', 'id', 'name'],
        conflictColumns: ['tenant_id', 'id'],
      );

      expect(
        sql,
        'INSERT INTO tasks (tenant_id, id, name) VALUES (?, ?, ?) ON CONFLICT (tenant_id, id) DO UPDATE SET name = EXCLUDED.name, is_deleted = 0, deleted_at = NULL',
      );
    });

    test('buildUpsertQuery respects excludedUpdates', () {
      final sql = SqlUtils.buildUpsertQuery(
        table: 'logs',
        columns: ['id', 'message', 'created_at'],
        conflictColumns: ['id'],
        excludedUpdates: ['created_at'],
      );

      expect(
        sql,
        'INSERT INTO logs (id, message, created_at) VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE SET message = EXCLUDED.message, is_deleted = 0, deleted_at = NULL',
      );
    });

    test('buildUpsertQuery throws on empty input', () {
      expect(
        () => SqlUtils.buildUpsertQuery(
          table: 't',
          columns: [],
          conflictColumns: ['id'],
        ),
        throwsArgumentError,
      );
      expect(
        () => SqlUtils.buildUpsertQuery(
          table: 't',
          columns: ['a'],
          conflictColumns: [],
        ),
        throwsArgumentError,
      );
    });
  });
}
