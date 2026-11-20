import 'package:postgres_crdt/postgres_crdt.dart' as pg;
import 'package:legacy_gantt_sync/server/services/operation_service.dart';
import 'package:legacy_gantt_sync/services/solver_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:test/test.dart';

class _Executor extends Mock implements CrdtExecutor {}

class _Solver extends Mock implements SolverService {}

void main() {
  const stale = '2026-01-01T00:00:09.000Z-0000-test';
  const deletion = '2026-01-01T00:00:10.000Z-0000-test';
  const restore = '2026-01-01T00:00:11.000Z-0000-test';
  late _Executor executor;
  late OperationService service;
  setUp(() {
    executor = _Executor();
    when(() => executor.hlc).thenReturn(pg.Hlc.now('server-fixture'));
    service = OperationService(_Solver());
    when(() => executor.execute(any(), any())).thenAnswer((_) async {});
  });

  for (final type in ['UPDATE_TASK', 'UPDATE_RESOURCE', 'UPDATE_DEPENDENCY']) {
    test(
      '$type keeps older/equal writes hidden and allows a newer restore',
      () async {
        when(() => executor.query(any(), any())).thenAnswer((invocation) async {
          final sql = invocation.positionalArguments.first as String;
          if (!sql.startsWith('SELECT *')) return [];
          return [
            {
              'id': 'entity',
              'predecessor_task_id': 'p',
              'successor_task_id': 's',
              'name': '',
              'parent_id': '',
              'gantt_type': 'person',
              'dependency_type': 'DELETE',
              'lag': 0,
              'metadata_json': '{}',
              'is_deleted': 1,
              'last_updated': deletion,
              'deleted_at': deletion,
              'field_timestamps': '{"isDeleted":"$deletion","name":"$stale"}',
            },
          ];
        });
        Map<String, dynamic> candidate() => {
          'id': 'entity',
          'name': 'Restored',
          'predecessorTaskId': 'p',
          'successorTaskId': 's',
          'type': type == 'UPDATE_RESOURCE' ? 'person' : 'finishToStart',
        };
        for (final clock in [stale, deletion]) {
          final data = candidate();
          await service.applySingleOperation(
            executor,
            'tenant',
            type,
            data,
            clock,
          );
          if (type == 'UPDATE_DEPENDENCY') {
            expect(data['type'], 'DELETE');
            expect(data['lag'], 0);
          } else {
            expect(data['isDeleted'], true);
            if (type == 'UPDATE_RESOURCE') expect(data['name'], '');
          }
        }
        final data = candidate();
        await service.applySingleOperation(
          executor,
          'tenant',
          type,
          data,
          restore,
        );
        expect(data['lastUpdated'], restore);
        if (type == 'UPDATE_DEPENDENCY') {
          expect(data['type'], 'finishToStart');
        } else {
          expect(data['isDeleted'], false);
          expect(data['name'], 'Restored');
        }
      },
    );
  }

  test(
    'bulk replay keeps historical fields without resurrecting tombstones',
    () async {
      when(() => executor.query(any(), any())).thenAnswer((invocation) async {
        if (!(invocation.positionalArguments.first as String).startsWith(
          'SELECT *',
        )) {
          return [];
        }
        return [
          {
            'id': 'hidden',
            'name': 'Old',
            'is_deleted': 1,
            'last_updated': deletion,
            'deleted_at': deletion,
            'field_timestamps':
                '{"isDeleted":"$deletion","name":"2026-01-01T00:00:08.000Z-0000-test"}',
          },
          {
            'id': 'live',
            'name': 'Newer live row',
            'is_deleted': 0,
            'last_updated': restore,
          },
        ];
      });
      final data = <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          {'id': 'hidden', 'name': 'Historical name', 'timestamp': stale},
          {'id': 'live', 'name': 'Older live name', 'timestamp': stale},
        ],
      };
      await service.applySingleOperation(
        executor,
        'tenant',
        'BULK_INSERT_TASK',
        data,
        restore,
      );
      final tasks = data['tasks'] as List;
      expect(tasks[0]['name'], 'Historical name');
      expect(tasks[0]['isDeleted'], true);
      expect(tasks[1]['name'], 'Newer live row');
      expect(tasks[1]['isDeleted'], false);
    },
  );
}
