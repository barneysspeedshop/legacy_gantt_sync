import 'dart:convert';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import '../../utils/sql_utils.dart';
import 'operation_handler.dart';

class InsertResourceHandler extends BaseOperationHandler {
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final attributes = getAttributes(operationData);
    if (attributes['id'] != null) {
      final columns = [
        'tenant_id',
        'id',
        'name',
        'parent_id',
        'gantt_type',
        'is_expanded',
        'last_updated',
        'sort_order',
        'metadata_json',
      ];
      final values = [
        tenantId,
        attributes['id'],
        attributes['name'],
        attributes['parentId'],
        attributes['type'] ??
            attributes['ganttType'] ??
            attributes['gantt_type'] ??
            'person',
        attributes['isExpanded'] ?? true,
        timestamp,
        attributes['sortOrder'],
        jsonEncode(ProtobufMapper.metadataFromJson(attributes)),
      ];

      final sql = SqlUtils.buildUpsertQuery(
        table: 'resources',
        columns: columns,
        conflictColumns: ['tenant_id', 'id'],
      );
      await executor.execute(sql, values);
    }
    return [];
  }
}

class DeleteResourceHandler extends BaseOperationHandler {
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final attributes = getAttributes(operationData);
    if (attributes['id'] != null) {
      await executor.execute(
        'UPDATE resources SET is_deleted = 1, deleted_at = ?, last_updated = ? WHERE tenant_id = ? AND id = ?',
        [timestamp, timestamp, tenantId, attributes['id']],
      );
    }
    return [];
  }
}
