import 'dart:convert';

import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart'
    show ProtobufMapper;
import 'package:postgres_crdt/postgres_crdt.dart';
import '../../utils/sql_utils.dart';
import 'operation_handler.dart';

class BulkUpsertTaskHandler extends BaseOperationHandler {
  @override
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  ) async {
    // Expecting operationData to contain 'tasks': [ ... list of task data ... ]
    final tasksDynamic = operationData['tasks'];
    if (tasksDynamic == null || tasksDynamic is! List || tasksDynamic.isEmpty) {
      return [];
    }

    final tasks = tasksDynamic.cast<Map<String, dynamic>>();

    // Parse Node ID and DateTime from HLC timestamp once
    String nodeId;
    String modifiedIso;
    try {
      final hlc = Hlc.parse(timestamp);
      nodeId = hlc.nodeId;
      modifiedIso = hlc.dateTime.toIso8601String();
    } catch (_) {
      nodeId = 'unknown'; // Fallback
      modifiedIso = DateTime.now().toIso8601String();
    }

    // Define the full set of columns we support for tasks
    final columns = [
      'tenant_id',
      'id',
      'hlc',
      'node_id',
      'modified', // Explicitly set modified
      'last_updated',
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
    ];

    final flatValues = <dynamic>[];

    for (final taskData in tasks) {
      final attributes = getAttributes(taskData);
      final id = attributes['id'];
      if (id == null) continue; // Skip invalid tasks

      // 1. tenant_id
      flatValues.add(tenantId);

      // 2. id
      flatValues.add(id);

      // 3. hlc
      flatValues.add(timestamp);

      // 4. node_id
      flatValues.add(nodeId);

      // 5. modified
      flatValues.add(modifiedIso);

      // 6. last_updated
      flatValues.add(timestamp);

      // 7. name
      flatValues.add(getValue(taskData, 'name'));

      // 8. start_date
      flatValues.add(getValue(taskData, 'start_date', ['startDate', 'start']));

      // 9. end_date
      flatValues.add(getValue(taskData, 'end_date', ['endDate', 'end']));

      // 10. parent_id
      flatValues.add(getValue(taskData, 'parent_id', ['parentId']));

      // 11. row_id
      flatValues.add(getValue(taskData, 'row_id', ['rowId']));

      // 12. gantt_type logic
      final hasGanttType =
          attributes.containsKey('gantt_type') ||
          attributes.containsKey('ganttType');
      final hasIsMilestone =
          attributes.containsKey('isMilestone') ||
          attributes.containsKey('is_milestone');
      final hasIsSummary =
          attributes.containsKey('isSummary') ||
          attributes.containsKey('is_summary');

      String? ganttType;
      if (hasGanttType) {
        ganttType = attributes['gantt_type'] ?? attributes['ganttType'];
      } else if (hasIsMilestone &&
          (attributes['isMilestone'] == true ||
              attributes['is_milestone'] == true)) {
        ganttType = 'milestone';
      } else if (hasIsSummary &&
          (attributes['isSummary'] == true ||
              attributes['is_summary'] == true)) {
        ganttType = 'project';
      } else {
        ganttType = 'task'; // Default
      }
      flatValues.add(ganttType);

      // 13. color
      flatValues.add(getValue(taskData, 'color'));

      // 14. text_color
      flatValues.add(getValue(taskData, 'text_color', ['textColor']));

      // 15. completion
      flatValues.add(getValue(taskData, 'completion'));

      // 16. resource_id
      flatValues.add(getValue(taskData, 'resource_id', ['resourceId']));

      // 17. baseline_start
      flatValues.add(getValue(taskData, 'baseline_start', ['baselineStart']));

      // 18. baseline_end
      flatValues.add(getValue(taskData, 'baseline_end', ['baselineEnd']));

      // 19. notes
      flatValues.add(getValue(taskData, 'notes'));

      // 20. uses_work_calendar
      flatValues.add(
        getValue(taskData, 'uses_work_calendar', ['usesWorkCalendar']),
      );

      // 21. propagates_move_to_children
      flatValues.add(
        getValue(taskData, 'propagates_move_to_children', [
          'propagatesMoveToChildren',
        ]),
      );

      // 22. resize_policy
      flatValues.add(getValue(taskData, 'resize_policy', ['resizePolicy']));
      flatValues.add(jsonEncode(ProtobufMapper.metadataFromJson(attributes)));
    }

    if (flatValues.isEmpty) return [];

    final rowCount = flatValues.length ~/ columns.length;

    // Explicitly cast to avoid "could not determine data type of parameter $N" errors
    final casts = [
      'text', // tenant_id
      'text', // id
      'text', // hlc
      'text', // node_id
      'text', // modified
      'text', // last_updated
      'text', // name
      'text', // start_date
      'text', // end_date
      'text', // parent_id
      'text', // row_id
      'text', // gantt_type
      'text', // color
      'text', // text_color
      'double precision', // completion
      'text', // resource_id
      'text', // baseline_start
      'text', // baseline_end
      'text', // notes
      'boolean', // uses_work_calendar
      'boolean', // propagates_move_to_children
      'text', // resize_policy
      'text', // metadata_json
    ];

    final sql = SqlUtils.buildBulkUpsertQuery(
      table: 'tasks',
      columns: columns,
      conflictColumns: ['tenant_id', 'id'],
      rowCount: rowCount,
      columnCasts: casts,
    );

    // Execute single massive insert
    await executor.execute(sql, flatValues);

    return [];
  }
}
