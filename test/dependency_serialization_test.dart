import 'dart:convert';

import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_sync/server/services/merkle_service.dart';
import 'package:test/test.dart';

void main() {
  test('tombstone buckets and payload use the causal deletion clock', () {
    const oldClock = '2024-01-01T00:00:00.000Z-0000-test';
    const deleteClock = '2024-01-01T00:02:00.000Z-0000-test';
    final row = <String, dynamic>{
      'id': 'deleted-resource',
      'name': 'Equipment',
      'gantt_type': 'tool',
      'is_deleted': 1,
      'last_updated': oldClock,
      'deleted_at': deleteClock,
    };
    final operation = CrdtService().formatResourceOperation(row);
    expect(operation['timestamp'], deleteClock);
    final resource = ProtobufMapper.resourceFromJson(
      operation['data'] as Map<String, dynamic>,
    );
    expect(resource.lastUpdated, deleteClock);
    final serverTree = MerkleService.buildTreeFromRows(
      tasks: [],
      dependencies: [],
      resources: [row],
    );
    final clientTree = MerkleTree.build([
      MapEntry(
        MerkleHashNormalizer.merkleHlcKey(deleteClock),
        resource.contentHash,
      ),
    ]);
    expect(serverTree.root.hash, clientTree.root.hash);
    expect(
      CrdtService.recordTimestamp({
        ...row,
        'last_updated': deleteClock,
        'deleted_at': oldClock,
      }),
      deleteClock,
    );
  });

  for (final deleted in [false, true]) {
    test(
      'task snapshot preserves canonical fields and Merkle parity (deleted: $deleted)',
      () {
        const timestamp = '2024-01-01T00:00:00.000Z-0000-test';
        final row = <String, dynamic>{
          'id': 'task-1',
          'name': 'Milestone',
          'row_id': 'row-1',
          'parent_id': 'parent-1',
          'resource_id': 'resource-1',
          'gantt_type': 'milestone',
          'completion': 0.5,
          'start_date': 1000,
          'end_date': 2000,
          'color': 255,
          'text_color': '#FFFFFF',
          'notes': 'Keep after deletion',
          'uses_work_calendar': 1,
          'propagates_move_to_children': 0,
          'metadata_json': jsonEncode({
            'originalId': 'source-1',
            'isAutoScheduled': false,
            'load': 2.0,
            'stackIndex': 3,
          }),
          'resize_policy': '1',
          'baseline_start': 500,
          'baseline_end': 2500,
          'is_deleted': deleted ? 1 : 0,
          'last_updated': timestamp,
        };
        final operation = CrdtService().formatTaskOperation(row);
        final message = ProtobufMapper.toProtobuf({
          'type': 'BATCH_UPDATE',
          'data': <String, dynamic>{
            'operations': [operation],
          },
        });
        final task = ProtocolMessage.fromBuffer(
          message.writeToBuffer(),
        ).batchUpdate.tasks.single;
        expect(task.id, 'task-1');
        expect(task.name, 'Milestone');
        expect(task.parentId, 'parent-1');
        expect(task.rowId, 'row-1');
        expect(task.resourceId, 'resource-1');
        expect(task.start, '1970-01-01T00:00:01.000Z');
        expect(task.end, '1970-01-01T00:00:02.000Z');
        expect(task.notes, 'Keep after deletion');
        expect(task.isMilestone, isTrue);
        expect(task.isDeleted, deleted);
        final metadata = jsonDecode(task.metadataJson) as Map<String, dynamic>;
        expect(metadata['textColor'], 'ffffffff');
        expect(metadata['color'], 'ff0000ff');
        expect(metadata['usesWorkCalendar'], isTrue);
        expect(metadata['propagatesMoveToChildren'], isFalse);
        expect(metadata['isAutoScheduled'], isFalse);
        expect(metadata['resizePolicy'], 'constrain');
        expect(metadata['originalId'], 'source-1');
        expect(metadata['load'], 2.0);
        expect(metadata['stackIndex'], 3);
        expect(metadata['baselineStart'], '1970-01-01T00:00:00.500Z');
        expect(metadata['baselineEnd'], '1970-01-01T00:00:02.500Z');
        final serverTree = MerkleService.buildTreeFromRows(
          tasks: [row],
          dependencies: [],
          resources: [],
        );
        final clientTree = MerkleTree.build([
          MapEntry(
            MerkleHashNormalizer.merkleHlcKey(timestamp),
            task.contentHash,
          ),
        ]);
        expect(clientTree.root.hash, serverTree.root.hash);
      },
    );
    test('dependency snapshot preserves Merkle parity (deleted: $deleted)', () {
      const timestamp = '2024-01-01T00:00:00.000Z-0000-test';
      final row = <String, dynamic>{
        'predecessor_task_id': 'p1',
        'successor_task_id': 's1',
        'dependency_type': 'contained',
        'lag': '4500',
        'is_deleted': deleted ? 1 : 0,
        'last_updated': timestamp,
      };
      final operation = CrdtService().formatDependencyOperation(row)!;
      final message = ProtobufMapper.toProtobuf({
        'type': 'BATCH_UPDATE',
        'data': <String, dynamic>{
          'operations': [operation],
        },
      });
      final dependency = ProtocolMessage.fromBuffer(
        message.writeToBuffer(),
      ).batchUpdate.dependencies.single;
      expect(dependency.predecessorTaskId, 'p1');
      expect(dependency.successorTaskId, 's1');
      expect(dependency.type, deleted ? 'DELETE' : 'contained');
      expect(dependency.lag.toInt(), 4500);
      final serverTree = MerkleService.buildTreeFromRows(
        tasks: [],
        dependencies: [row],
        resources: [],
      );
      final clientTree = MerkleTree.build([
        MapEntry(
          MerkleHashNormalizer.merkleHlcKey(timestamp),
          dependency.contentHash,
        ),
      ]);
      expect(clientTree.root.hash, serverTree.root.hash);
    });
  }
  for (final deleted in [false, true]) {
    test('resource snapshot preserves Merkle parity (deleted: $deleted)', () {
      const timestamp = '2024-01-01T00:00:00.000Z-0000-test';
      final row = <String, dynamic>{
        'id': 'resource-1',
        'name': 'Equipment',
        'parent_id': 'group-1',
        'gantt_type': 'tool',
        'metadata_json': jsonEncode({
          'category': 'equipment',
          'custom': {'rate': 3},
        }),
        'is_expanded': false,
        'is_deleted': deleted ? 1 : 0,
        'last_updated': timestamp,
      };
      final operation = CrdtService().formatResourceOperation(row);
      final message = ProtobufMapper.toProtobuf({
        'type': 'BATCH_UPDATE',
        'data': <String, dynamic>{
          'operations': [operation],
        },
      });
      final resource = ProtocolMessage.fromBuffer(
        message.writeToBuffer(),
      ).batchUpdate.resources.single;
      expect(resource.id, 'resource-1');
      expect(resource.name, 'Equipment');
      expect(resource.parentId, 'group-1');
      expect(resource.type, 'tool');
      expect(resource.isDeleted, deleted);
      expect(resource.metadataJson, contains('"isExpanded":false'));
      expect(jsonDecode(resource.metadataJson)['category'], 'equipment');
      expect(jsonDecode(resource.metadataJson)['custom'], {'rate': 3});
      final serverTree = MerkleService.buildTreeFromRows(
        tasks: [],
        dependencies: [],
        resources: [row],
      );
      final clientTree = MerkleTree.build([
        MapEntry(
          MerkleHashNormalizer.merkleHlcKey(timestamp),
          resource.contentHash,
        ),
      ]);
      expect(clientTree.root.hash, serverTree.root.hash);
    });
  }

  test('database dependency TEXT lag survives binary snapshots', () {
    final operation = CrdtService().formatDependencyOperation({
      'is_deleted': 0,
      'predecessor_task_id': 'p1',
      'successor_task_id': 's1',
      'dependency_type': 'contained',
      'lag': '4500',
      'last_updated': '2024-01-01T00:00:00.000Z-0000-test',
    })!;
    final message = ProtobufMapper.toProtobuf(operation);
    final decoded = ProtocolMessage.fromBuffer(message.writeToBuffer());
    expect(decoded.singleOperation.dependency.predecessorTaskId, 'p1');
    expect(decoded.singleOperation.dependency.successorTaskId, 's1');
    expect(decoded.singleOperation.dependency.type, 'contained');
    expect(decoded.singleOperation.dependency.lag.toInt(), 4500);
  });
}
