import 'package:legacy_gantt_sync/services/solver_service.dart';
import 'package:postgres_crdt/postgres_crdt.dart' hide Hlc;
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart' show Hlc;
import 'crdt_service.dart';
import 'package:legacy_gantt_sync/server/constants/protocol_constants.dart';
import 'handlers/operation_handler.dart';
import 'handlers/dependency_handlers.dart';
import 'handlers/reset_handler.dart';
import 'handlers/task_handlers.dart';
import 'handlers/resource_handlers.dart';
import 'handlers/optimization_handler.dart';
import 'handlers/bulk_task_handlers.dart';

class OperationService {
  final SolverService solverService;
  late final Map<String, OperationHandler> _handlers;

  OperationService(this.solverService) {
    _handlers = {
      ProtocolConstants.insertDependency: InsertDependencyHandler(),
      ProtocolConstants.updateDependency: InsertDependencyHandler(),
      ProtocolConstants.deleteDependency: DeleteDependencyHandler(),
      ProtocolConstants.resetData: ResetDataHandler(),
      ProtocolConstants.insertTask: UpsertTaskHandler(),
      ProtocolConstants.updateTask:
          UpsertTaskHandler(), // Both map to same logic
      ProtocolConstants.deleteTask: DeleteTaskHandler(),
      ProtocolConstants.insertResource: InsertResourceHandler(),
      ProtocolConstants.updateResource: InsertResourceHandler(),
      ProtocolConstants.deleteResource: DeleteResourceHandler(),
      ProtocolConstants.optimizeSchedule: OptimizeScheduleHandler(
        solverService,
      ),
      'BULK_INSERT_TASK': BulkUpsertTaskHandler(),
    };
  }

  Future<List<Map<String, dynamic>>> applySingleOperation(
    CrdtExecutor executor,
    String tenantId,
    String type,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final handler = _handlers[type];
    if (handler == null) return [];
    if (handler is BaseOperationHandler) {
      if (type == 'BULK_INSERT_TASK') {
        final tasks = (operationData['tasks'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        final ids = tasks
            .map((task) => handler.getAttributes(task)['id'])
            .whereType<String>()
            .toSet();
        if (ids.isNotEmpty) {
          final rows = await executor.query(
            'SELECT id, is_deleted, last_updated, deleted_at FROM tasks WHERE tenant_id = ? AND id IN (${List.filled(ids.length, '?').join(', ')}) FOR UPDATE',
            [tenantId, ...ids],
          );
          final existing = {for (final row in rows) row['id']: row};
          operationData['tasks'] = tasks.where((task) {
            final row = existing[handler.getAttributes(task)['id']];
            final clock = task['timestamp']?.toString() ?? timestamp;
            return row == null || !_isStaleResurrection(row, clock);
          }).toList();
        }
      } else if (_upsertTypes.contains(type)) {
        final attributes = handler.getAttributes(operationData);
        final String sql;
        final List<Object?> parameters;
        if (type.contains('TASK')) {
          sql =
              'SELECT is_deleted, last_updated, deleted_at FROM tasks WHERE tenant_id = ? AND id = ? FOR UPDATE';
          parameters = [tenantId, attributes['id']];
        } else if (type.contains('RESOURCE')) {
          sql =
              'SELECT is_deleted, last_updated, deleted_at FROM resources WHERE tenant_id = ? AND id = ? FOR UPDATE';
          parameters = [tenantId, attributes['id']];
        } else {
          sql =
              'SELECT is_deleted, last_updated, deleted_at FROM dependencies WHERE tenant_id = ? AND predecessor_task_id = ? AND successor_task_id = ? FOR UPDATE';
          parameters = [
            tenantId,
            attributes['predecessorTaskId'],
            attributes['successorTaskId'],
          ];
        }
        final rows = await executor.query(sql, parameters);
        if (rows.isNotEmpty && _isStaleResurrection(rows.single, timestamp)) {
          throw const StaleTombstoneOperation();
        }
      }
    }
    return handler.handle(executor, tenantId, operationData, timestamp);
  }

  static const _upsertTypes = {
    ProtocolConstants.insertTask,
    ProtocolConstants.updateTask,
    ProtocolConstants.insertResource,
    ProtocolConstants.updateResource,
    ProtocolConstants.insertDependency,
    ProtocolConstants.updateDependency,
  };

  static bool _isStaleResurrection(Map<String, dynamic> row, String timestamp) {
    final deleted = row['is_deleted'];
    if (deleted != true &&
        deleted != 1 &&
        deleted != '1' &&
        deleted != 'true') {
      return false;
    }
    return Hlc.parse(timestamp) <= Hlc.parse(CrdtService.recordTimestamp(row));
  }
}

class StaleTombstoneOperation implements Exception {
  const StaleTombstoneOperation();

  @override
  String toString() => 'Stale operation cannot resurrect a newer tombstone';
}
