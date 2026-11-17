import 'package:legacy_gantt_sync/server/constants/protocol_constants.dart';
import 'package:legacy_gantt_sync/server/services/operation_service.dart';
import 'package:legacy_gantt_sync/services/solver_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:test/test.dart';

class MockSolverService extends Mock implements SolverService {}

class MockCrdtExecutor extends Mock implements CrdtExecutor {}

void main() {
  late OperationService operationService;
  late MockSolverService mockSolverService;
  late MockCrdtExecutor mockExecutor;

  setUp(() {
    mockSolverService = MockSolverService();
    mockExecutor = MockCrdtExecutor();
    operationService = OperationService(mockSolverService);

    // Default behaviors
    when(() => mockExecutor.execute(any(), any())).thenAnswer((_) async => {});
    when(() => mockExecutor.query(any(), any())).thenAnswer((_) async => []);
  });

  group('OperationService', () {
    test('INSERT_TASK delegates to UpsertTaskHandler', () async {
      final opData = {
        'id': 'task-1',
        'name': 'New Task',
        'startDate': '2023-01-01',
        'endDate': '2023-01-05',
      };

      await operationService.applySingleOperation(
        mockExecutor,
        'tenant-1',
        ProtocolConstants.insertTask,
        opData,
        '2023-01-01T00:00:00.000Z',
      );

      // Verify execute was called (checking for table name to differentiate)
      verify(
        () => mockExecutor.execute(
          any(that: contains('tasks')),
          any(that: contains('task-1')),
        ),
      ).called(1);
    });

    test('INSERT_DEPENDENCY delegates to InsertDependencyHandler', () async {
      final opData = {
        'predecessorTaskId': 'task-1',
        'successorTaskId': 'task-2',
        'type': 'finishToStart',
      };

      await operationService.applySingleOperation(
        mockExecutor,
        'tenant-1',
        ProtocolConstants.insertDependency,
        opData,
        '2023-01-01T00:00:00.000Z',
      );

      verify(
        () => mockExecutor.execute(
          any(that: contains('dependencies')),
          any(that: containsAll(['task-1', 'task-2'])),
        ),
      ).called(1);
    });

    test('OPTIMIZE_SCHEDULE delegates to OptimizeScheduleHandler', () async {
      when(
        () => mockSolverService.optimizeSchedule(any()),
      ).thenAnswer((_) async => []);

      await operationService.applySingleOperation(
        mockExecutor,
        'tenant-1',
        ProtocolConstants.optimizeSchedule,
        {},
        '2023-01-01T00:00:00.000Z',
      );

      // Verify queries were made to fetch tasks and dependencies
      verify(
        () => mockExecutor.query(any(that: contains('SELECT')), any()),
      ).called(2);
      // Verify solver called
      verify(() => mockSolverService.optimizeSchedule(any())).called(1);
    });

    test('Unknown operation returns empty list', () async {
      final result = await operationService.applySingleOperation(
        mockExecutor,
        'tenant-1',
        'UNKNOWN_OP',
        {},
        '2023-01-01T00:00:00.000Z',
      );

      expect(result, isEmpty);
      verifyNever(() => mockExecutor.execute(any(), any()));
    });
  });
}
