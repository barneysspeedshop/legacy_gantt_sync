import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:test/test.dart';
import 'package:legacy_gantt_sync/services/solver_bindings.dart';
import 'package:legacy_gantt_sync/services/solver_service.dart';

void main() {
  group('Solver FFI Integration', () {
    test('Bindings load library successfully', () {
      // This will throw if library cannot be loaded
      final bindings = GanttSolverBindings();
      expect(bindings, isNotNull);
    });

    test('experimental solver rejects scheduling through FFI', () {
      final bindings = GanttSolverBindings();

      final input = SolverRequest().writeToBuffer();

      final result = bindings.solveCriticalPath(input);

      final decoded = SolverResponse.fromBuffer(result);
      expect(decoded.success, isFalse);
      expect(
        decoded.errorMessage,
        'Scheduling is experimental and not implemented',
      );
    });

    test('SolverService surfaces the experimental scheduling error', () async {
      final service = SolverService();
      await expectLater(
        service.optimizeSchedule([
          {'id': 'a', 'start': 0, 'end': 1000},
          {'id': 'b', 'start': 0, 'end': 1000},
        ]),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Scheduling is experimental and not implemented'),
          ),
        ),
      );
    });
  });
}
