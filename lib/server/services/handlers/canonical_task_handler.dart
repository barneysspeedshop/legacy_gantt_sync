import 'dart:convert';

import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:postgres_crdt/postgres_crdt.dart' hide Hlc;

import '../crdt_service.dart';

/// Materializes the shared protocol reducer in PostgreSQL, including field clocks.
class CanonicalTaskHandler {
  Map<String, dynamic> getAttributes(Map<String, dynamic> data) {
    var attributes = data;
    while (attributes['data'] is Map<String, dynamic>) {
      attributes = attributes['data'] as Map<String, dynamic>;
    }
    return attributes;
  }

  final _engine = CRDTEngine();
  final _formatter = CrdtService();

  Future<List<Operation>> apply(
    CrdtExecutor executor,
    String tenantId,
    List<Operation> operations, {
    Hlc? reset,
  }) async {
    final ids = operations
        .map((operation) => getAttributes(operation.data)['id'])
        .whereType<String>()
        .toSet();
    if (ids.isEmpty) return [];
    final rows = await executor.query(
      'SELECT * FROM tasks WHERE tenant_id = ? AND id IN (${List.filled(ids.length, '?').join(', ')}) FOR UPDATE',
      [tenantId, ...ids],
    );
    final state = <String, ProtocolTask>{};
    for (final row in rows) {
      final data =
          _formatter.formatTaskOperation(row)['data'] as Map<String, dynamic>;
      final task = ProtobufMapper.taskFromJson(data);
      state[task.id] = task;
    }
    final changed = <String, ProtocolTask>{};
    final accepted = <Operation>[];
    for (final operation in operations) {
      final data = getAttributes(operation.data);
      final id = data['id'] as String?;
      if (id == null) continue;
      final fieldTimestamps = data['fieldTimestamps'];
      if (fieldTimestamps is Map) {
        for (final value in fieldTimestamps.values) {
          if (value is! String || Hlc.parse(value) > operation.timestamp) {
            throw const FormatException(
              'Task field clock exceeds its operation clock',
            );
          }
        }
      }
      final existing = state[id];
      var current = existing == null ? <ProtocolTask>[] : [existing];
      if (reset != null) {
        current = _engine.mergeTasks(current, [
          Operation(
            type: 'DELETE_TASK',
            data: {'id': id},
            timestamp: reset,
            actorId: 'reset',
          ),
        ]);
      }
      final merged = _engine.mergeTasks(current, [operation]).single;
      final payload = ProtobufMapper.taskToJson(merged);
      operation.data
        ..clear()
        ..addAll(payload);
      state[id] = merged;
      accepted.add(operation);
      if (existing == null ||
          base64Encode(existing.writeToBuffer()) !=
              base64Encode(merged.writeToBuffer())) {
        changed[id] = merged;
      }
    }
    if (changed.isEmpty) return accepted;
    const columns = [
      'tenant_id',
      'id',
      'name',
      'start_date',
      'end_date',
      'parent_id',
      'row_id',
      'gantt_type',
      'color',
      'text_color',
      'completion',
      'resource_id',
      'baseline_start',
      'baseline_end',
      'notes',
      'uses_work_calendar',
      'propagates_move_to_children',
      'resize_policy',
      'metadata_json',
      'field_timestamps',
      'hlc',
      'node_id',
      'modified',
      'last_updated',
      'is_deleted',
      'deleted_at',
    ];
    const casts = [
      'text',
      'text',
      'text',
      'text',
      'text',
      'text',
      'text',
      'text',
      'text',
      'text',
      'double precision',
      'text',
      'text',
      'text',
      'text',
      'boolean',
      'boolean',
      'text',
      'text',
      'text',
      'text',
      'text',
      'text',
      'text',
      'integer',
      'text',
    ];
    final values = <Object?>[];
    for (final task in changed.values) {
      final metadata = ProtobufMapper.metadataFromJson({
        'metadataJson': task.metadataJson,
      });
      values.addAll([
        tenantId,
        task.id,
        task.name,
        task.start,
        task.end,
        task.parentId,
        task.rowId,
        task.isMilestone
            ? 'milestone'
            : task.isSummary
            ? 'project'
            : 'task',
        metadata['color'],
        metadata['textColor'],
        task.completion,
        task.resourceId,
        metadata['baselineStart'],
        metadata['baselineEnd'],
        task.notes,
        metadata['usesWorkCalendar'] == true,
        metadata['propagatesMoveToChildren'] != false,
        MerkleHashNormalizer.normalizeResizePolicy(metadata['resizePolicy']),
        task.metadataJson,
        jsonEncode(task.fieldTimestamps),
        executor.hlc.toString(),
        executor.hlc.nodeId,
        executor.hlc.toString(),
        task.lastUpdated,
        task.isDeleted ? 1 : 0,
        task.isDeleted ? task.lastUpdated : null,
      ]);
    }
    final placeholders = '(${casts.map((cast) => '?::$cast').join(', ')})';
    final updates = columns
        .where((column) => column != 'tenant_id' && column != 'id')
        .map((column) => '$column = EXCLUDED.$column')
        .join(', ');
    await executor.execute(
      'INSERT INTO tasks (${columns.join(', ')}) VALUES ${List.filled(changed.length, placeholders).join(', ')} '
      'ON CONFLICT (tenant_id, id) DO UPDATE SET $updates',
      values,
    );
    return accepted;
  }
}
