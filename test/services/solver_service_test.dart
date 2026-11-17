import 'dart:typed_data';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:legacy_gantt_sync/services/solver_service.dart';
import 'package:legacy_gantt_sync/services/solver_bindings.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockGanttSolverBindings extends Mock implements GanttSolverBindings {}

void main() {
  group('SolverService', () {
    late SolverService solverService;
    late MockGanttSolverBindings mockBindings;

    setUpAll(() {
      registerFallbackValue(Uint8List(0));
    });

    setUp(() {
      mockBindings = MockGanttSolverBindings();
      solverService = SolverService(bindings: mockBindings);
    });

    test('optimizeSchedule calls bindings with correct payload', () async {
      final tasks = [
        {
          'id': '1',
          'resourceId': 'r1',
          'start_date': '2023-01-01T00:00:00Z',
          'end_date': '2023-01-02T00:00:00Z',
          'gantt_type': 'task',
        },
        {
          'id': '2',
          'resourceId': 'r1',
          'start': 1672617600000,
          'end': 1672704000000,
        },
      ];

      final mockRustResult = SolverResponse()
        ..success = true
        ..tasks.addAll([
          ProtocolTask()
            ..id = '1'
            ..start = '100'
            ..end = '200',
          ProtocolTask()
            ..id = '2'
            ..start = '300'
            ..end = '400',
        ]);

      when(
        () => mockBindings.solveCriticalPath(any()),
      ).thenReturn(mockRustResult.writeToBuffer());

      final result = await solverService.optimizeSchedule(tasks);

      expect(result.length, 2);
      expect(result[0]['start'], 100);

      // Verify call
      final captured = verify(
        () => mockBindings.solveCriticalPath(captureAny()),
      ).captured;

      final inputBytes = captured.first as Uint8List;
      final request = SolverRequest.fromBuffer(inputBytes);
      final sentTasks = request.tasks;

      expect(sentTasks[0].start, isNotEmpty);
      expect(sentTasks[1].start, '1672617600000');
    });

    test('optimizeSchedule throws on bindings failure', () async {
      final errorResult = SolverResponse()
        ..success = false
        ..errorMessage = 'Rust Panic';

      when(
        () => mockBindings.solveCriticalPath(any()),
      ).thenReturn(errorResult.writeToBuffer());

      expect(() => solverService.optimizeSchedule([]), throwsException);
    });
  });
}
