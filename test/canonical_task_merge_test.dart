import 'package:postgres_crdt/postgres_crdt.dart' as pg;
import 'dart:convert';

import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_sync/server/services/operation_service.dart';
import 'package:legacy_gantt_sync/services/solver_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:postgres_crdt/postgres_crdt.dart' hide Hlc;
import 'package:test/test.dart';

class _Executor extends Mock implements CrdtExecutor {}

class _Solver extends Mock implements SolverService {}

Hlc clock(int value) => Hlc(millis: value, counter: 0, nodeId: 'fixture');

void main() {
  late _Executor executor;
  late OperationService service;
  late Map<String, Map<String, dynamic>> rows;
  setUp(() {
    executor = _Executor();
    when(() => executor.hlc).thenReturn(pg.Hlc.now('server-fixture'));
    service = OperationService(_Solver());
    rows = {};
    when(() => executor.query(any(), any())).thenAnswer((invocation) async {
      final sql = invocation.positionalArguments[0] as String;
      if (sql.contains('pg_advisory_xact_lock')) return [];
      final parameters = invocation.positionalArguments[1] as List;
      return [
        for (final id in parameters.skip(1))
          if (rows[id] != null) Map<String, dynamic>.from(rows[id]!),
      ];
    });
    when(() => executor.execute(any(), any())).thenAnswer((invocation) async {
      final sql = invocation.positionalArguments[0] as String;
      final columns = sql
          .substring(sql.indexOf('(') + 1, sql.indexOf(')'))
          .split(', ');
      final values = invocation.positionalArguments[1] as List;
      for (var offset = 0; offset < values.length; offset += columns.length) {
        final row = <String, dynamic>{
          for (var index = 0; index < columns.length; index++)
            columns[index]: values[offset + index],
        };
        rows[row['id'] as String] = row;
      }
    });
  });

  test(
    'server materializes independent delayed full-snapshot fields and clocks',
    () async {
      Future<void> apply(int timestamp, Map<String, dynamic> data) =>
          service.applySingleOperation(executor, 'tenant', 'UPDATE_TASK', {
            'id': 'task',
            ...data,
          }, clock(timestamp).toString());
      await apply(100, {'name': 'Original', 'notes': 'Original notes'});
      await apply(300, {
        'name': 'New name',
        'notes': 'Original notes',
        'fieldTimestamps': {
          'name': clock(300).toString(),
          'notes': clock(100).toString(),
        },
      });
      await apply(200, {
        'name': 'Original',
        'notes': 'Offline notes',
        'fieldTimestamps': {
          'name': clock(100).toString(),
          'notes': clock(200).toString(),
        },
      });
      final row = rows['task']!;
      expect(row['name'], 'New name');
      expect(row['notes'], 'Offline notes');
      expect(row['last_updated'], clock(300).toString());
      final fields = jsonDecode(row['field_timestamps'] as String) as Map;
      expect(fields['name'], clock(300).toString());
      expect(fields['notes'], clock(200).toString());
      final data = CrdtService().formatTaskOperation(row)['data'] as Map;
      expect(data['fieldTimestamps'], fields);
    },
  );

  test('bulk task insertion preserves each operation clock', () async {
    await service.applySingleOperation(executor, 'tenant', 'BULK_INSERT_TASK', {
      'tasks': [
        <String, dynamic>{
          'id': 'first',
          'name': 'First',
          'timestamp': clock(100).toString(),
        },
        <String, dynamic>{
          'id': 'second',
          'name': 'Second',
          'timestamp': clock(200).toString(),
        },
      ],
    }, clock(200).toString());
    expect(rows['first']!['last_updated'], clock(100).toString());
    expect(rows['second']!['last_updated'], clock(200).toString());
    expect(
      pg.Hlc.parse(rows['first']!['modified'] as String).nodeId,
      'server-fixture',
    );
    expect(
      pg.Hlc.parse(rows['second']!['hlc'] as String).nodeId,
      'server-fixture',
    );
  });

  test('delayed delete cannot remove a newer task', () async {
    await service.applySingleOperation(executor, 'tenant', 'UPDATE_TASK', {
      'id': 'task',
      'name': 'Retained',
    }, clock(300).toString());
    await service.applySingleOperation(
      executor,
      'tenant',
      'DELETE_TASK',
      <String, dynamic>{'id': 'task'},
      clock(200).toString(),
    );
    expect(rows['task']!['name'], 'Retained');
    expect(rows['task']!['is_deleted'], 0);
  });
  test('reset fence is rechecked after acquiring the tenant lock', () async {
    when(() => executor.query(any(), any())).thenAnswer((invocation) async {
      final sql = invocation.positionalArguments[0] as String;
      return sql.contains('project_metadata')
          ? [
              {'last_reset_at': clock(300).toString()},
            ]
          : [];
    });
    await service.applySingleOperation(
      executor,
      'tenant',
      'INSERT_TASK',
      <String, dynamic>{'id': 'late', 'name': 'Historical'},
      clock(200).toString(),
    );
    expect(rows['late']!['is_deleted'], 1);
    expect(rows['late']!['name'], 'Historical');
    expect(rows['late']!['last_updated'], clock(300).toString());
  });
  test(
    'deleting an unseen task persists the offline canonical tombstone',
    () async {
      final deletion = Operation(
        type: 'DELETE_TASK',
        data: {'id': 'unseen'},
        timestamp: clock(200),
        actorId: 'fixture',
      );
      await service.applySingleOperation(
        executor,
        'tenant',
        deletion.type,
        Map<String, dynamic>.from(deletion.data),
        deletion.timestamp.toString(),
      );
      final expected = CRDTEngine().mergeTasks([], [deletion]).single;
      final payload =
          CrdtService().formatTaskOperation(rows['unseen']!)['data']
              as Map<String, dynamic>;
      expect(
        ProtobufMapper.taskFromJson(payload).contentHash,
        expected.contentHash,
      );
      expect(rows['unseen']!['is_deleted'], 1);
      expect(rows['unseen']!['last_updated'], clock(200).toString());
    },
  );
  test(
    'wire deletion defaults cannot erase the retained task content',
    () async {
      await service.applySingleOperation(
        executor,
        'tenant',
        'INSERT_TASK',
        <String, dynamic>{
          'id': 'task',
          'name': 'Full task',
          'notes': 'Retained notes',
        },
        clock(100).toString(),
      );
      final wire = ProtobufMapper.toJson(
        ProtobufMapper.toProtobuf(
          Operation(
            type: 'DELETE_TASK',
            data: {'id': 'task'},
            timestamp: clock(200),
            actorId: 'fixture',
          ).toJson(),
        ),
      );
      await service.applySingleOperation(
        executor,
        'tenant',
        'DELETE_TASK',
        wire['data'] as Map<String, dynamic>,
        clock(200).toString(),
      );
      expect(rows['task']!['name'], 'Full task');
      expect(rows['task']!['notes'], 'Retained notes');
      expect(rows['task']!['is_deleted'], 1);
    },
  );

  test(
    'full clocked deletion snapshots recover historical fields for unknown IDs',
    () async {
      final engine = CRDTEngine();
      final task = engine.mergeTasks([], [
        Operation(
          type: 'UPDATE_TASK',
          data: {'id': 'task', 'name': 'Historical', 'notes': 'Offline notes'},
          timestamp: clock(100),
          actorId: 'fixture',
        ),
        Operation(
          type: 'DELETE_TASK',
          data: {'id': 'task'},
          timestamp: clock(200),
          actorId: 'fixture',
        ),
      ]).single;
      await service.applySingleOperation(
        executor,
        'tenant',
        'DELETE_TASK',
        ProtobufMapper.taskToJson(task),
        clock(200).toString(),
      );
      expect(rows['task']!['name'], 'Historical');
      expect(rows['task']!['notes'], 'Offline notes');
      expect(rows['task']!['is_deleted'], 1);
      final restored = ProtobufMapper.taskFromJson(
        CrdtService().formatTaskOperation(rows['task']!)['data']
            as Map<String, dynamic>,
      );
      expect(restored.contentHash, task.contentHash);
    },
  );
  test('field clocks cannot bypass the validated operation clock', () async {
    await expectLater(
      service.applySingleOperation(
        executor,
        'tenant',
        'INSERT_TASK',
        <String, dynamic>{
          'id': 'future',
          'name': 'Rejected',
          'fieldTimestamps': {'name': clock(200).toString()},
        },
        clock(100).toString(),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(rows, isEmpty);
    verifyNever(() => executor.execute(any(), any()));
  });
}
