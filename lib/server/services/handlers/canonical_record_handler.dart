import 'dart:convert';

import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:postgres_crdt/postgres_crdt.dart' hide Hlc;

import '../crdt_service.dart';
import 'dependency_handlers.dart';
import 'resource_handlers.dart';

/// Resources and dependencies are complete LWW records with minimal tombstones.
class CanonicalRecordHandler {
  final _engine = CRDTEngine();
  final _formatter = CrdtService();

  Future<void> apply(
    CrdtExecutor executor,
    String tenantId,
    Operation operation, {
    Hlc? reset,
  }) async {
    final data = operation.data;
    if (operation.type.contains('RESOURCE')) {
      final id = data['id'] as String;
      final rows = await executor.query(
        'SELECT * FROM resources WHERE tenant_id = ? AND id = ? FOR UPDATE',
        [tenantId, id],
      );
      ProtocolResource? existing;
      if (rows.isNotEmpty) {
        existing = ProtobufMapper.resourceFromJson(
          _formatter.formatResourceOperation(rows.single)['data']
              as Map<String, dynamic>,
        );
      }
      var state = existing == null ? <ProtocolResource>[] : [existing];
      if (reset != null) {
        state = _engine.mergeResources(state, [
          Operation(
            type: 'DELETE_RESOURCE',
            data: {'id': id},
            timestamp: reset,
            actorId: 'reset',
          ),
        ]);
      }
      final merged = _engine.mergeResources(state, [operation]).single;
      final payload = ProtobufMapper.resourceToJson(merged);
      operation.data
        ..clear()
        ..addAll(payload);
      if (existing != null &&
          base64Encode(existing.writeToBuffer()) ==
              base64Encode(merged.writeToBuffer())) {
        return;
      }
      await InsertResourceHandler().handle(
        executor,
        tenantId,
        payload,
        merged.lastUpdated,
      );
      if (merged.isDeleted) {
        await DeleteResourceHandler().handle(executor, tenantId, {
          'id': id,
        }, merged.lastUpdated);
      }
      return;
    }
    final predecessor = data['predecessorTaskId'] as String;
    final successor = data['successorTaskId'] as String;
    final rows = await executor.query(
      'SELECT * FROM dependencies WHERE tenant_id = ? AND predecessor_task_id = ? AND successor_task_id = ? FOR UPDATE',
      [tenantId, predecessor, successor],
    );
    ProtocolDependency? existing;
    if (rows.isNotEmpty) {
      final snapshot = _formatter.formatDependencyOperation(rows.single)!;
      existing = ProtobufMapper.dependencyFromJson(
        snapshot['data'] as Map<String, dynamic>,
      );
      if (snapshot['type'] == 'DELETE_DEPENDENCY') existing.type = 'DELETE';
    }
    var merged = existing;
    ProtocolDependency tombstone(Hlc clock) =>
        ProtobufMapper.dependencyFromJson({
          'predecessorTaskId': predecessor,
          'successorTaskId': successor,
          'type': 'DELETE',
          'lag': 0,
          'lastUpdated': clock.toString(),
        });
    if (reset != null &&
        (merged == null || merged.parsedLastUpdated <= reset)) {
      merged = tombstone(reset);
    }
    final deleted =
        operation.type == 'DELETE_DEPENDENCY' || data['type'] == 'DELETE';
    if (merged == null ||
        operation.timestamp > merged.parsedLastUpdated ||
        (operation.timestamp == merged.parsedLastUpdated &&
            (deleted || merged.type != 'DELETE'))) {
      merged = deleted
          ? tombstone(operation.timestamp)
          : (ProtobufMapper.dependencyFromJson(data)
              ..lastUpdated = operation.timestamp.toString());
    }
    final payload = ProtobufMapper.dependencyToJson(merged);
    operation.data
      ..clear()
      ..addAll(payload);
    if (existing != null &&
        base64Encode(existing.writeToBuffer()) ==
            base64Encode(merged.writeToBuffer())) {
      return;
    }
    await InsertDependencyHandler().handle(
      executor,
      tenantId,
      payload,
      merged.lastUpdated,
    );
    if (merged.type == 'DELETE') {
      await DeleteDependencyHandler().handle(
        executor,
        tenantId,
        payload,
        merged.lastUpdated,
      );
    }
  }
}
