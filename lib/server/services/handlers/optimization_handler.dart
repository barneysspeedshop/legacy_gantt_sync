import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:legacy_gantt_sync/services/solver_service.dart';
import '../../constants/protocol_constants.dart';
import '../../../utils/logger.dart';
import 'operation_handler.dart';

class OptimizeScheduleHandler extends BaseOperationHandler {
  final SolverService _solverService;

  OptimizeScheduleHandler(this._solverService);

  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final tasksData = await executor.query(
      'SELECT * FROM tasks WHERE tenant_id = ? AND (is_deleted = 0 OR is_deleted IS NULL)',
      [tenantId],
    );
    final depsData = await executor.query(
      'SELECT * FROM dependencies WHERE tenant_id = ? AND (is_deleted = 0 OR is_deleted IS NULL)',
      [tenantId],
    );

    final tasks = tasksData.map((row) {
      final map = Map<String, dynamic>.from(row);
      final taskId = map['id'];

      map['dependencies'] = depsData
          .where((d) => d['successor_task_id'] == taskId)
          .map((d) => d['predecessor_task_id'])
          .toList();
      return map;
    }).toList();

    final taskMap = {for (final t in tasks) t['id']: t};

    try {
      final optimizedTasks = await _solverService.optimizeSchedule(tasks);
      final List<Map<String, dynamic>> generatedOps = [];
      final newTimestamp = DateTime.now().toIso8601String();

      for (final optimized in optimizedTasks) {
        final id = optimized['id'];
        final start = optimized['start'];
        final end = optimized['end'];

        final startVal = start?.toString();
        final endVal = end?.toString();

        await executor.execute(
          'UPDATE tasks SET start_date = ?, end_date = ?, last_updated = ? WHERE tenant_id = ? AND id = ?',
          [
            startVal,
            endVal,
            newTimestamp, // HLC/ISO string
            tenantId,
            id,
          ],
        );

        final original = taskMap[id];
        final completion = original?['completion'];

        generatedOps.add({
          'type': ProtocolConstants.updateTask,
          'data': {
            'id': id,
            'start_date': start,
            'end_date': end,
            'completion': ?completion,
          },
          'timestamp': newTimestamp,
          'actorId': 'server-solver',
        });
      }
      return generatedOps;
    } catch (e) {
      JsonLogger.error('OPTIMIZATION_FAILED', {'error': e.toString()});
      rethrow;
    }
  }
}
