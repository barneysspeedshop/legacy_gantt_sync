import 'package:postgres_crdt/postgres_crdt.dart' show CrdtExecutor;
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart' show Hlc;
import 'package:legacy_gantt_sync/server/services/handlers/operation_handler.dart';

class ResetDataHandler extends BaseOperationHandler {
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final metadata = await executor.query(
      'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ? FOR UPDATE',
      [tenantId],
    );
    final previousReset = metadata.isEmpty
        ? null
        : metadata.single['last_reset_at'];
    if (previousReset != null &&
        Hlc.parse(previousReset.toString()) >= Hlc.parse(timestamp)) {
      return [];
    }
    await executor.execute(
      'UPDATE tasks SET is_deleted = 1, deleted_at = ?, last_updated = ? WHERE tenant_id = ?',
      [timestamp, timestamp, tenantId],
    );
    await executor.execute(
      'UPDATE dependencies SET is_deleted = 1, deleted_at = ?, last_updated = ? WHERE tenant_id = ?',
      [timestamp, timestamp, tenantId],
    );
    await executor.execute(
      'UPDATE resources SET is_deleted = 1, deleted_at = ?, last_updated = ? WHERE tenant_id = ?',
      [timestamp, timestamp, tenantId],
    );

    await executor.execute(
      '''
      INSERT INTO project_metadata (tenant_id, last_reset_at, last_updated)
      VALUES (?, ?, ?)
      ON CONFLICT (tenant_id) DO UPDATE SET
        last_reset_at = EXCLUDED.last_reset_at,
        last_updated = EXCLUDED.last_updated
    ''',
      [tenantId, timestamp, timestamp],
    );

    return [];
  }
}
