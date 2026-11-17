import 'package:postgres_crdt/postgres_crdt.dart';
import '../../utils/sql_utils.dart';
import 'operation_handler.dart';

class InsertDependencyHandler extends BaseOperationHandler {
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final pred = getValue(operationData, 'predecessorTaskId');
    final succ = getValue(operationData, 'successorTaskId');
    final depType =
        getValue(operationData, 'dependency_type', [
          'dependencyType',
          'type',
        ]) ??
        'finishToStart';
    final lag = getValue(operationData, 'lag');

    final columns = [
      'tenant_id',
      'predecessor_task_id',
      'successor_task_id',
      'dependency_type',
      'lag',
      'last_updated',
    ];
    final sql = SqlUtils.buildUpsertQuery(
      table: 'dependencies',
      columns: columns,
      conflictColumns: [
        'tenant_id',
        'predecessor_task_id',
        'successor_task_id',
      ],
    );
    await executor.execute(sql, [
      tenantId,
      pred,
      succ,
      depType,
      lag,
      timestamp,
    ]);

    return [];
  }
}

class DeleteDependencyHandler extends BaseOperationHandler {
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final pred = getValue(operationData, 'predecessorTaskId');
    final succ = getValue(operationData, 'successorTaskId');

    await executor.execute(
      'UPDATE dependencies SET is_deleted = 1, deleted_at = ?, last_updated = ? WHERE tenant_id = ? AND predecessor_task_id = ? AND successor_task_id = ?',
      [timestamp, timestamp, tenantId, pred, succ],
    );

    return [];
  }
}
