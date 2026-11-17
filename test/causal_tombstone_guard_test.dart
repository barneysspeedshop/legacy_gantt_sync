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
    service = OperationService(_Solver());
    when(() => executor.execute(any(), any())).thenAnswer((_) async {});
  });

  for (final type in ['UPDATE_TASK', 'UPDATE_RESOURCE', 'UPDATE_DEPENDENCY']) {
    test(
      '$type rejects older/equal tombstone clocks but accepts a newer restore',
      () async {
        when(() => executor.query(any(), any())).thenAnswer(
          (_) async => [
            {'is_deleted': 1, 'last_updated': stale, 'deleted_at': deletion},
          ],
        );
        final data = <String, dynamic>{
          'id': 'entity',
          'name': 'Restored',
          'predecessorTaskId': 'p',
          'successorTaskId': 's',
          'type': 'finishToStart',
        };
        for (final timestamp in [stale, deletion]) {
          await expectLater(
            service.applySingleOperation(
              executor,
              'tenant',
              type,
              data,
              timestamp,
            ),
            throwsA(isA<StaleTombstoneOperation>()),
          );
        }
        await service.applySingleOperation(
          executor,
          'tenant',
          type,
          data,
          restore,
        );
        final arguments =
            verify(() => executor.execute(any(), captureAny())).captured.single
                as List;
        expect(arguments, contains(restore));
        expect(
          arguments,
          contains(type == 'UPDATE_DEPENDENCY' ? 'p' : 'entity'),
        );
      },
    );
  }

  test(
    'bulk filtering rejects stale tombstone rows and preserves live/newer rows',
    () async {
      when(() => executor.query(any(), any())).thenAnswer(
        (_) async => [
          {
            'id': 'stale',
            'is_deleted': 1,
            'last_updated': stale,
            'deleted_at': deletion,
          },
          {
            'id': 'restore',
            'is_deleted': 1,
            'last_updated': stale,
            'deleted_at': deletion,
          },
          {'id': 'live', 'is_deleted': 0, 'last_updated': restore},
        ],
      );
      final data = <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          {'id': 'stale', 'name': 'Rejected stale row', 'timestamp': stale},
          {'id': 'restore', 'name': 'Restored row', 'timestamp': restore},
          {'id': 'live', 'name': 'Independent live row', 'timestamp': stale},
        ],
      };
      await service.applySingleOperation(
        executor,
        'tenant',
        'BULK_INSERT_TASK',
        data,
        restore,
      );
      expect((data['tasks'] as List).map((task) => task['id']).toList(), [
        'restore',
        'live',
      ]);
      final arguments =
          verify(() => executor.execute(any(), captureAny())).captured.single
              as List;
      expect(arguments, contains('Restored row'));
      expect(arguments, contains('Independent live row'));
      expect(arguments, isNot(contains('Rejected stale row')));
    },
  );
}
