import 'package:postgres_crdt/postgres_crdt.dart' show CrdtExecutor;
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart'
    show Hlc, Operation;
import 'canonical_task_handler.dart';
import 'package:legacy_gantt_sync/server/services/handlers/operation_handler.dart';

class ResetDataHandler extends BaseOperationHandler {
  final CanonicalTaskHandler _tasks;
  ResetDataHandler({CanonicalTaskHandler? tasks})
    : _tasks = tasks ?? CanonicalTaskHandler();
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final resetTimestamp = Hlc.parse(timestamp).toString();
    final metadata = await executor.query(
      'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ? FOR UPDATE',
      [tenantId],
    );
    final previousReset = metadata.isEmpty
        ? null
        : metadata.single['last_reset_at'];
    if (previousReset != null &&
        Hlc.parse(previousReset.toString()) >= Hlc.parse(resetTimestamp)) {
      return [];
    }
    final taskRows = await executor.query(
      'SELECT id FROM tasks WHERE tenant_id = ?',
      [tenantId],
    );
    for (var start = 0; start < taskRows.length; start += 500) {
      final end = start + 500 < taskRows.length ? start + 500 : taskRows.length;
      await _tasks.apply(executor, tenantId, [
        for (final row in taskRows.sublist(start, end))
          Operation(
            type: 'DELETE_TASK',
            data: {'id': row['id']},
            timestamp: Hlc.parse(resetTimestamp),
            actorId: 'reset',
          ),
      ]);
    }
    await executor.execute(
      "UPDATE dependencies SET is_deleted = 1, dependency_type = 'DELETE', lag = 0, deleted_at = ?, last_updated = ? WHERE tenant_id = ? AND GREATEST(COALESCE(last_updated, ''), COALESCE(deleted_at, '')) <= ?",
      [resetTimestamp, resetTimestamp, tenantId, resetTimestamp],
    );
    await executor.execute(
      "UPDATE resources SET is_deleted = 1, name = '', parent_id = '', gantt_type = 'person', is_expanded = TRUE, sort_order = NULL, metadata_json = '{}', deleted_at = ?, last_updated = ? WHERE tenant_id = ? AND GREATEST(COALESCE(last_updated, ''), COALESCE(deleted_at, '')) <= ?",
      [resetTimestamp, resetTimestamp, tenantId, resetTimestamp],
    );

    await executor.execute(
      '''
      INSERT INTO project_metadata (tenant_id, last_reset_at, last_updated)
      VALUES (?, ?, ?)
      ON CONFLICT (tenant_id) DO UPDATE SET
        last_reset_at = EXCLUDED.last_reset_at,
        last_updated = EXCLUDED.last_updated
    ''',
      [tenantId, resetTimestamp, resetTimestamp],
    );

    return [];
  }
}
