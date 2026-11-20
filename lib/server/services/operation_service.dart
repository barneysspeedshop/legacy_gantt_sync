import 'package:legacy_gantt_sync/services/solver_service.dart';
import 'package:postgres_crdt/postgres_crdt.dart' hide Hlc;
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart'
    show Hlc, Operation;
import 'package:legacy_gantt_sync/server/constants/protocol_constants.dart';
import 'handlers/operation_handler.dart';
import 'handlers/dependency_handlers.dart';
import 'handlers/reset_handler.dart';
import 'handlers/resource_handlers.dart';
import 'handlers/optimization_handler.dart';
import 'handlers/canonical_task_handler.dart';
import 'handlers/canonical_record_handler.dart';

class OperationService {
  final SolverService solverService;
  final _tasks = CanonicalTaskHandler();
  final _records = CanonicalRecordHandler();
  late final Map<String, OperationHandler> _handlers;

  OperationService(this.solverService) {
    _handlers = {
      ProtocolConstants.insertDependency: InsertDependencyHandler(),
      ProtocolConstants.updateDependency: InsertDependencyHandler(),
      ProtocolConstants.deleteDependency: DeleteDependencyHandler(),
      ProtocolConstants.resetData: ResetDataHandler(tasks: _tasks),
      ProtocolConstants.insertResource: InsertResourceHandler(),
      ProtocolConstants.updateResource: InsertResourceHandler(),
      ProtocolConstants.deleteResource: DeleteResourceHandler(),
      ProtocolConstants.optimizeSchedule: OptimizeScheduleHandler(
        solverService,
      ),
    };
  }

  Future<List<Map<String, dynamic>>> applySingleOperation(
    CrdtExecutor executor,
    String tenantId,
    String type,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final taskOperation = const {
      'INSERT_TASK',
      'UPDATE_TASK',
      'DELETE_TASK',
      'BULK_INSERT_TASK',
    }.contains(type);
    if (taskOperation ||
        _entityTypes.contains(type) ||
        type == ProtocolConstants.resetData) {
      // Serialize each tenant's reset and entity writes across server instances.
      await executor.query(
        'SELECT pg_advisory_xact_lock(hashtextextended(?, 0))',
        [tenantId],
      );
    }
    Hlc? reset;
    if (type != ProtocolConstants.resetData &&
        (taskOperation || _entityTypes.contains(type))) {
      final rows = await executor.query(
        'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ?',
        [tenantId],
      );
      final value = rows.firstOrNull?['last_reset_at'];
      if (value != null) reset = Hlc.parse(value.toString());
    }
    if (taskOperation) {
      final List<Operation> operations;
      if (type == 'BULK_INSERT_TASK') {
        operations = (operationData['tasks'] as List? ?? []).map((raw) {
          final data = raw as Map<String, dynamic>;
          return Operation(
            type: data.remove('_taskOperationType') as String? ?? 'INSERT_TASK',
            data: data,
            timestamp: Hlc.parse(data['timestamp']?.toString() ?? timestamp),
            actorId: 'server-operation',
          );
        }).toList();
      } else {
        operations = [
          Operation(
            type: type,
            data: operationData,
            timestamp: Hlc.parse(timestamp),
            actorId: 'server-operation',
          ),
        ];
      }
      final accepted = await _tasks.apply(
        executor,
        tenantId,
        operations,
        reset: reset,
      );
      if (type == 'BULK_INSERT_TASK') {
        operationData['tasks'] = accepted
            .map((operation) => operation.data)
            .toList();
      } else if (accepted.isEmpty) {
        throw const StaleTombstoneOperation();
      }
      return [];
    }
    final handler = _handlers[type];
    if (handler == null) return [];
    if (_entityTypes.contains(type)) {
      await _records.apply(
        executor,
        tenantId,
        Operation(
          type: type,
          data: operationData,
          timestamp: Hlc.parse(timestamp),
          actorId: 'server-operation',
        ),
        reset: reset,
      );
      return [];
    }
    return handler.handle(executor, tenantId, operationData, timestamp);
  }

  static const _entityTypes = {
    ProtocolConstants.insertResource,
    ProtocolConstants.updateResource,
    ProtocolConstants.deleteResource,
    ProtocolConstants.insertDependency,
    ProtocolConstants.updateDependency,
    ProtocolConstants.deleteDependency,
  };
}

/// A delayed operation has already been superseded and must not be broadcast.
class StaleTombstoneOperation implements Exception {
  const StaleTombstoneOperation();
  @override
  String toString() => 'Operation has been superseded by newer entity state';
}
