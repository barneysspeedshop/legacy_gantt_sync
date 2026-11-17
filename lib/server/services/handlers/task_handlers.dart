import 'dart:convert';

import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import '../../utils/sql_utils.dart';
import 'operation_handler.dart';

class UpsertTaskHandler extends BaseOperationHandler {
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    final attributes = getAttributes(operationData);

    if (attributes['id'] != null) {
      final id = attributes['id'];

      final columns = ['tenant_id', 'id', 'last_updated'];
      final values = [tenantId, id, timestamp];

      void addIfPresent(String column, String key, [List<String>? aliases]) {
        if (attributes.containsKey(key) ||
            (aliases != null &&
                aliases.any((a) => attributes.containsKey(a))) ||
            operationData.containsKey(key) ||
            (aliases != null &&
                aliases.any((a) => operationData.containsKey(a)))) {
          columns.add(column);
          values.add(getValue(operationData, key, aliases));
        }
      }

      addIfPresent('name', 'name');
      addIfPresent('start_date', 'start_date', ['startDate', 'start']);
      addIfPresent('end_date', 'end_date', ['endDate', 'end']);
      addIfPresent('parent_id', 'parent_id', ['parentId']);
      addIfPresent('row_id', 'row_id', ['rowId']);

      final hasGanttType =
          attributes.containsKey('gantt_type') ||
          attributes.containsKey('ganttType');
      final hasIsMilestone =
          attributes.containsKey('isMilestone') ||
          attributes.containsKey('is_milestone');
      final hasIsSummary =
          attributes.containsKey('isSummary') ||
          attributes.containsKey('is_summary');

      if (hasGanttType || hasIsMilestone || hasIsSummary) {
        final isMilestone =
            attributes['isMilestone'] == true ||
            attributes['is_milestone'] == true;
        final isSummary =
            attributes['isSummary'] == true || attributes['is_summary'] == true;

        String derivedType = 'task';
        if (isMilestone) {
          derivedType = 'milestone';
        } else if (isSummary) {
          derivedType = 'project';
        }
        final ganttType =
            attributes['gantt_type'] ?? attributes['ganttType'] ?? derivedType;
        columns.add('gantt_type');
        values.add(ganttType);
      }

      addIfPresent('color', 'color');
      addIfPresent('text_color', 'text_color', ['textColor']);
      addIfPresent('completion', 'completion');
      addIfPresent('resource_id', 'resource_id', ['resourceId']);
      addIfPresent('baseline_start', 'baseline_start', ['baselineStart']);
      addIfPresent('baseline_end', 'baseline_end', ['baselineEnd']);
      addIfPresent('notes', 'notes');
      addIfPresent('uses_work_calendar', 'uses_work_calendar', [
        'usesWorkCalendar',
      ]);
      addIfPresent(
        'propagates_move_to_children',
        'propagates_move_to_children',
        ['propagatesMoveToChildren'],
      );
      addIfPresent('resize_policy', 'resize_policy', ['resizePolicy']);

      final metadata = ProtobufMapper.metadataFromJson(attributes);
      if (metadata.isNotEmpty || attributes.containsKey('metadataJson')) {
        columns.add('metadata_json');
        values.add(jsonEncode(metadata));
      }

      final sql = SqlUtils.buildUpsertQuery(
        table: 'tasks',
        columns: columns,
        conflictColumns: ['tenant_id', 'id'],
      );

      await executor.execute(sql, values);
    }

    return [];
  }
}

class DeleteTaskHandler extends BaseOperationHandler {
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
        'UPDATE tasks SET is_deleted = 1, deleted_at = ?, last_updated = ? WHERE tenant_id = ? AND id = ?',
        [timestamp, timestamp, tenantId, attributes['id']],
      );
    }

    return [];
  }
}
