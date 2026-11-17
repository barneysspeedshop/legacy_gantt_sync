import 'dart:convert';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'solver_bindings.dart';

class SolverService {
  final GanttSolverBindings _bindings;

  SolverService({GanttSolverBindings? bindings})
    : _bindings = bindings ?? GanttSolverBindings();

  /// Takes the current project tasks, sends them to the Rust Solver via FFI,
  /// and returns the optimized list of tasks with new start/end dates.
  Future<List<Map<String, dynamic>>> optimizeSchedule(
    List<Map<String, dynamic>> tasks,
  ) async {
    // 1. Prepare Payload
    final cleanTasks = tasks.map((t) {
      final pt = ProtocolTask()
        ..id = t['id']?.toString() ?? ''
        ..resourceId = (t['resourceId'] ?? t['resource_id'])?.toString() ?? ''
        ..start = _toEpoch(t['start_date'] ?? t['start']).toString()
        ..end = _toEpoch(t['end_date'] ?? t['end']).toString()
        ..metadataJson = jsonEncode({
          'ganttType': t['ganttType'] ?? t['gantt_type'],
        });
      return pt;
    }).toList();

    JsonLogger.info('SOLVER_REQUEST', {'task_count': cleanTasks.length});

    // 2. Call the Rust Solver via FFI
    try {
      final request = SolverRequest()
        ..tasks.addAll(cleanTasks)
        ..algorithmLevel = 0;

      final resultBytes = _bindings.solveCriticalPath(request.writeToBuffer());

      final decoded = SolverResponse.fromBuffer(resultBytes);

      if (decoded.success) {
        if (decoded.tasks.isNotEmpty) {
          return decoded.tasks.map((pt) {
            return {
              'id': pt.id,
              'resourceId': pt.resourceId,
              'start': int.tryParse(pt.start),
              'end': int.tryParse(pt.end),
              'start_date': int.tryParse(pt.start),
              'end_date': int.tryParse(pt.end),
              // Decode metadata if needed, but for now just return the map
            };
          }).toList();
        }
        return [];
      } else {
        throw Exception('Solver Error: ${decoded.errorMessage}');
      }
    } catch (e) {
      JsonLogger.error('SOLVER_FAIL', {'error': e.toString()});
      rethrow;
    }
  }

  /// Helper to ensure we transmit Integers to Solver
  int _toEpoch(dynamic dateInput) {
    if (dateInput == null) return 0;
    if (dateInput is int) return dateInput;
    if (dateInput is String) {
      return DateTime.parse(dateInput).millisecondsSinceEpoch;
    }
    if (dateInput is DateTime) return dateInput.millisecondsSinceEpoch;
    return 0; // Fallback
  }
}
