import 'package:test/test.dart';
import 'package:legacy_gantt_sync/server/services/handlers/dependency_handlers.dart';
import 'package:postgres_crdt/postgres_crdt.dart';

// Simple mock executor using noSuchMethod to capture calls
class SimpleMockExecutor implements CrdtExecutor {
  String? lastSql;
  List<Object?>? lastArgs;

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    lastSql = sql;
    lastArgs = args;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('InsertDependencyHandler Repro', () {
    test('Should handle flat payload with contained type', () async {
      final handler = InsertDependencyHandler();
      final executor = SimpleMockExecutor();

      final opData = {
        'predecessorTaskId': 'p1',
        'successorTaskId': 's1',
        'dependency_type': 'contained',
      };

      await handler.handle(
        executor,
        'tenant1',
        opData,
        '2022-01-01T00:00:00.000Z',
      );

      print('SQL: ${executor.lastSql}');
      print('Args: ${executor.lastArgs}');

      expect(executor.lastArgs, contains('contained'));
    });

    test('Should handle nested payload (backward compatibility)', () async {
      final handler = InsertDependencyHandler();
      final executor = SimpleMockExecutor();

      final opData = {
        'data': {
          'predecessorTaskId': 'p1',
          'successorTaskId': 's1',
          'dependency_type': 'contained',
        },
      };

      await handler.handle(
        executor,
        'tenant1',
        opData,
        '2022-01-01T00:00:00.000Z',
      );

      expect(executor.lastArgs, contains('contained'));
    });
  });
}
