import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:example/data/local/gantt_db.dart';
import 'package:example/data/local/local_gantt_repository.dart';
import 'package:example/data/local/protocol_state_store.dart';
import 'package:example/view_models/gantt_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legacy_gantt_chart/legacy_gantt_chart.dart'
    show LegacyGanttTask;
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart' hide Hlc;
import 'package:web_socket_channel/io.dart';

class Peer {
  final IOWebSocketChannel channel;
  final StreamQueue<dynamic> messages;
  Peer(this.channel) : messages = StreamQueue(channel.stream);
  void send(Operation op) =>
      channel.sink.add(ProtobufMapper.toProtobuf(op.toJson()).writeToBuffer());
  Future<Operation> until(bool Function(Operation) predicate) async {
    while (true) {
      final raw = await messages.next.timeout(const Duration(seconds: 10));
      final json = ProtobufMapper.toJson(
        ProtocolMessage.fromBuffer(raw as List<int>),
      );
      if (json['type'] == 'ERROR') fail('Server error: ${json['error']}');
      final op = Operation.fromJson({
        ...json,
        'data': {
          ...?json['data'] as Map<String, dynamic>?,
          if (json['channel'] != null) '__responseChannel': json['channel'],
        },
        'timestamp': json['timestamp'] ?? Hlc.zero.toString(),
        'actorId': json['actorId'] ?? '',
      });
      if (predicate(op)) return op;
    }
  }

  int _rootRequest = 0;
  Future<Operation> merkleRoot() async {
    final nonce = 'fixture-root-${++_rootRequest}';
    channel.sink.add(
      ProtobufMapper.toProtobuf({
        'type': 'GET_MERKLE_ROOT',
        'data': <String, dynamic>{},
        'timestamp': Hlc.zero.toString(),
        'actorId': 'verifier',
        'channel': nonce,
      }).writeToBuffer(),
    );
    return until(
      (operation) =>
          operation.type == 'MERKLE_ROOT' &&
          operation.data['__responseChannel'] == nonce,
    );
  }

  Future<void> snapshot(ProtocolStateStore store) async {
    final metadata = await until((op) => op.type == 'SYNC_METADATA');
    var remaining = metadata.data['totalOperations'] as int;
    while (remaining > 0) {
      final batch = await until((op) => op.type == 'BATCH_UPDATE');
      await store.applyOperations([batch]);
      remaining -= (batch.data['operations'] as List).length;
    }
  }

  Future<void> close() async {
    await messages.cancel(immediate: true);
    await channel.sink.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  Process? server;
  late String base;
  late String ws;
  Future<void> startServer() async {
    final port = Completer<int>();
    final env = Platform.environment;
    server = await Process.start(
      'dart',
      ['bin/server.dart'],
      workingDirectory: Directory.current.parent.parent.path,
      environment: {
        'LEGACY_GANTT_SYNC_PORT': '0',
        'JWT_SECRET': 'canonical-integration-test-only',
        'DB_HOST': '127.0.0.1',
        'DB_PORT': env['TEST_DB_PORT']!,
        'DB_USER': 'dart_user',
        'DB_PASS': env['TEST_DB_PASS']!,
        'DB_NAME': 'legacy_gantt',
        'DB_SSL_MODE': 'disable',
        'REDIS_HOST': '127.0.0.1',
        'REDIS_PORT': env['TEST_REDIS_PORT']!,
        'SUPERUSER_USERNAME': 'superuser',
        'SUPERUSER_PASSWORD': 'superuser',
      },
    );
    server!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.contains('"level":"ERROR"') ||
              line.contains('"level":"WARN"')) {
            final record = jsonDecode(line) as Map<String, dynamic>;
            final details = record['data'] as Map<String, dynamic>;
            print('Integration server ${record['event']}: ${details['error']}');
          }
          if (line.contains('SERVER_START') && !port.isCompleted) {
            port.complete(jsonDecode(line)['data']['port'] as int);
          }
        });
    server!.stderr
        .transform(utf8.decoder)
        .listen((line) => print('Server stderr: $line'));
    final number = await port.future.timeout(const Duration(seconds: 30));
    base = 'http://127.0.0.1:$number';
    ws = 'ws://127.0.0.1:$number/ws';
  }

  setUpAll(startServer);
  tearDownAll(() async {
    server?.kill();
    await server?.exitCode;
  });
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    String? token,
  }) async {
    final response = await http.post(
      Uri.parse('$base$path'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
    expect(response.statusCode, 200, reason: '$path: ${response.body}');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  test('real clients retain offline edits through restart, connection and cold replay', () async {
    final unique = DateTime.now().microsecondsSinceEpoch;
    final superuser = await post('/auth/login', {
      'username': 'superuser',
      'password': 'superuser',
    });
    final username = 'offline-admin-$unique';
    final tenant = await post('/api/admin/tenants', {
      'tenantName': 'offline-$unique',
      'adminUsername': username,
      'adminPassword': 'test-password',
    }, token: superuser['accessToken'] as String);
    final tenantId = tenant['tenantId'] as String;
    final directory = await Directory.systemTemp.createTemp(
      'gantt-real-offline-',
    );
    final clients = <GanttViewModel>[];
    final databases = <SqliteCrdt>[];
    addTearDown(() async {
      for (final client in clients.reversed) {
        await client.disposeAsync();
      }
      for (final database in databases.reversed) {
        await database.close();
      }
      await directory.delete(recursive: true);
    });
    Future<GanttViewModel> open(String name) async {
      final db = await GanttDb.open('${directory.path}/$name.sqlite');
      databases.add(db);
      await db.execute(
        'INSERT OR REPLACE INTO sync_metadata (meta_key, meta_value) VALUES (?, ?)',
        [
          'canonical_scope',
          jsonEncode([ws, tenantId]),
        ],
      );
      final client = GanttViewModel(
        database: Future.value(db),
        useLocalDatabase: true,
      );
      clients.add(client);
      await client.initialized;
      return client;
    }

    Future<void> waitFor(
      GanttViewModel client,
      bool Function() predicate,
    ) async {
      final complete = Completer<void>();
      void changed() {
        if (predicate() && !complete.isCompleted) complete.complete();
      }

      client.addListener(changed);
      try {
        changed();
        await complete.future.timeout(const Duration(seconds: 10));
      } finally {
        client.removeListener(changed);
      }
    }

    Future<void> connect(GanttViewModel client) => client.connectSync(
      uri: base,
      tenantId: tenantId,
      username: username,
      password: 'test-password',
    );
    LegacyGanttTask task(String id) => LegacyGanttTask(
      id: id,
      rowId: 'row',
      name: 'Offline $id',
      notes: 'Preserved $id',
      start: DateTime.utc(2026, 11, 20),
      end: DateTime.utc(2026, 11, 21),
    );

    var a = await open('a');
    await a.addResources([LocalResource(id: 'row', name: 'Team')]);
    await a.addTask(task('a'));
    expect(a.allTasks.single.name, 'Offline a');
    await a.disposeAsync();
    clients.remove(a);
    await databases.first.close();
    databases.removeAt(0);
    a = await open('a');
    expect(a.allTasks.single.notes, 'Preserved a');
    final b = await open('b');
    await connect(b);
    final receivedA = waitFor(
      b,
      () => b.allTasks.any((task) => task.id == 'a'),
    );
    await connect(a);
    await receivedA;
    expect(a.allTasks.single.name, 'Offline a');
    expect(b.allTasks.single.name, 'Offline a');
    expect(b.localResources.single.name, 'Team');
    expect(b.localResources.single.parentId, isNull);

    final receivedB = waitFor(
      a,
      () => a.allTasks.any((task) => task.id == 'b'),
    );
    await b.addTask(task('b'));
    expect(
      b.allTasks.map((task) => task.name),
      unorderedEquals(['Offline a', 'Offline b']),
    );
    await receivedB;
    expect(
      a.allTasks.map((task) => task.name),
      unorderedEquals(['Offline a', 'Offline b']),
    );
    final cold = await open('cold');
    final receivedCold = waitFor(
      cold,
      () => cold.allTasks.length == 2 && cold.localResources.length == 1,
    );
    await connect(cold);
    await receivedCold;
    expect(
      cold.allTasks.map((task) => task.notes),
      unorderedEquals(['Preserved a', 'Preserved b']),
    );
    final roots = await Future.wait(
      databases.map(
        (db) => ProtocolStateStore(
          Future.value(db),
          scope: jsonEncode([ws, tenantId]),
        ).computeMerkleTree(),
      ),
    );
    Map<String, dynamic> taskRecord(String payload) {
      final task = ProtocolTask.fromBuffer(base64Decode(payload));
      final data = {
        ...ProtobufMapper.taskToJson(task),
        ...MerkleHashNormalizer.normalizeTaskMetadata(
          ProtobufMapper.metadataFromJson({'metadataJson': task.metadataJson}),
        ),
      }..remove('lastUpdatedBy');
      (data['fieldTimestamps'] as Map).removeWhere(
        (key, _) => const {
          'startIsUtc',
          'endIsUtc',
          'baselineStartIsUtc',
          'baselineEndIsUtc',
        }.contains(key),
      );
      return data;
    }

    Future<Map<String, Object?>> records(
      SqliteCrdt db, {
      String? scope,
    }) async => {
      for (final row in await db.query(
        'SELECT entity_type, entity_id, payload FROM canonical_protocol_state WHERE scope = ?',
        [
          scope ?? jsonEncode([ws, tenantId]),
        ],
      ))
        '${row['entity_type']}:${row['entity_id']}':
            switch (row['entity_type']) {
              'task' => taskRecord(row['payload'] as String),
              'resource' => ProtobufMapper.resourceToJson(
                ProtocolResource.fromBuffer(
                  base64Decode(row['payload'] as String),
                ),
              ),
              _ => row['payload'],
            },
    };
    final expectedRecords = await records(databases.first);
    for (var index = 1; index < databases.length; index++) {
      expect(
        await records(databases[index]),
        expectedRecords,
        reason: 'All accepted protocol fields must converge for client $index',
      );
    }
    expect(roots.map((tree) => tree.root.hash).toSet(), hasLength(1));
    final auth = await post('/auth/login', {
      'username': username,
      'password': 'test-password',
    });
    final verifier = Peer(
      IOWebSocketChannel.connect(
        ws,
        headers: {'Authorization': 'Bearer ${auth['accessToken']}'},
      ),
    );
    final replayDatabase = await GanttDb.open(inMemoryDatabasePath);
    try {
      await verifier.channel.ready;
      verifier.send(
        Operation(
          type: 'subscribe',
          data: {'channel': tenantId},
          timestamp: Hlc.zero,
          actorId: 'verifier',
        ),
      );
      await verifier.snapshot(ProtocolStateStore(Future.value(replayDatabase)));
      final serverRoot = await verifier.merkleRoot();
      expect(roots.first.root.hash, serverRoot.data['root']);

      final taskRow = (await databases.first.query(
        "SELECT payload FROM canonical_protocol_state WHERE scope = ? AND entity_type = 'task' AND entity_id = 'a'",
        [
          jsonEncode([ws, tenantId]),
        ],
      )).single;
      final original = ProtocolTask.fromBuffer(
        base64Decode(taskRow['payload'] as String),
      );
      final future = DateTime.now().millisecondsSinceEpoch + 1000;
      final nameClock = Hlc(
        millis: future + 10,
        counter: 0,
        nodeId: 'name-editor',
      );
      final notesClock = Hlc(
        millis: future + 5,
        counter: 0,
        nodeId: 'notes-editor',
      );
      final nameEdit = original.deepCopy()
        ..name = 'Independent name edit'
        ..lastUpdated = nameClock.toString();
      nameEdit.fieldTimestamps['name'] = nameClock.toString();
      final notesEdit = original.deepCopy()
        ..notes = 'Independent earlier notes edit'
        ..lastUpdated = notesClock.toString();
      notesEdit.fieldTimestamps['notes'] = notesClock.toString();
      for (final edit in [nameEdit, notesEdit]) {
        verifier.send(
          Operation(
            type: 'UPDATE_TASK',
            data: ProtobufMapper.taskToJson(edit),
            timestamp: edit.parsedLastUpdated,
            actorId: 'independent-editor',
          ),
        );
      }
      for (final client in [a, b, cold]) {
        await waitFor(
          client,
          () => client.allTasks.any(
            (task) =>
                task.id == 'a' &&
                task.name == 'Independent name edit' &&
                task.notes == 'Independent earlier notes edit',
          ),
        );
      }
      final expectedMergedRoot = (await ProtocolStateStore(
        Future.value(databases.first),
        scope: jsonEncode([ws, tenantId]),
      ).computeMerkleTree()).root.hash;
      final mergedRoot = await verifier.merkleRoot();
      expect(mergedRoot.data['root'], expectedMergedRoot);
      verifier.send(
        Operation(
          type: 'subscribe',
          data: {'channel': tenantId},
          timestamp: Hlc.zero,
          actorId: 'verifier',
        ),
      );
      await verifier.snapshot(ProtocolStateStore(Future.value(replayDatabase)));
      final mergedRecords = await records(replayDatabase, scope: 'local');
      for (final db in databases) {
        expect(
          await records(db),
          mergedRecords,
          reason: 'Live independent edits must match a fresh server replay',
        );
        expect(
          (await ProtocolStateStore(
            Future.value(db),
            scope: jsonEncode([ws, tenantId]),
          ).computeMerkleTree()).root.hash,
          mergedRoot.data['root'],
        );
      }
    } finally {
      await verifier.close();
      await replayDatabase.close();
    }
  });

  for (final batchDelete in [false, true]) {
    test(
      'live canonical deletes match server and cold replay (batch: $batchDelete)',
      () async {
        final unique = DateTime.now().microsecondsSinceEpoch;
        final superuser = await post('/auth/login', {
          'username': 'superuser',
          'password': 'superuser',
        });
        final tenant = await post('/api/admin/tenants', {
          'tenantName': 'canonical-$unique',
          'adminUsername': 'canonical-admin-$unique',
          'adminPassword': 'test-password',
        }, token: superuser['accessToken'] as String);
        final auth = await post('/auth/login', {
          'username': 'canonical-admin-$unique',
          'password': 'test-password',
        });
        final token = auth['accessToken'] as String;
        final tenantId = tenant['tenantId'] as String;
        final dbs = <SqliteCrdt>[];
        final peers = <Peer>[];
        addTearDown(() async {
          for (final peer in peers) {
            await peer.close();
          }
          for (final db in dbs) {
            await db.close();
          }
        });
        Future<ProtocolStateStore> newStore() async {
          final db = await GanttDb.open(inMemoryDatabasePath);
          dbs.add(db);
          return ProtocolStateStore(Future.value(db));
        }

        Future<Peer> connect(ProtocolStateStore state) async {
          final peer = Peer(
            IOWebSocketChannel.connect(
              ws,
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
          peers.add(peer);
          await peer.channel.ready;
          peer.send(
            Operation(
              type: 'subscribe',
              data: {'channel': tenantId},
              timestamp: Hlc.zero,
              actorId: 'fixture',
            ),
          );
          await peer.snapshot(state);
          return peer;
        }

        var tick = 0;
        Operation operation(String type, Map<String, dynamic> data) =>
            Operation(
              type: type,
              data: data,
              timestamp: Hlc.fromDate(
                DateTime.now().add(Duration(milliseconds: ++tick)),
                'network-fixture',
              ),
              actorId: 'network-fixture',
            );
        final senderState = await newStore();
        final observerState = await newStore();
        final sender = await connect(senderState);
        final observer = await connect(observerState);
        final writes = [
          operation('UPDATE_TASK', {
            'id': 'task-1',
            'rowId': 'row-1',
            'name': 'Full task',
            'start': '2024-01-01T00:00:00.000Z',
            'end': '2024-01-02T00:00:00.000Z',
            'notes': 'Keep after delete',
            'resourceId': 'resource-1',
            'metadataJson': jsonEncode({
              'stackIndex': 3,
              'load': 2.0,
              'custom': {'externalId': 'custom-42'},
            }),
          }),
          operation('INSERT_RESOURCE', {
            'id': 'resource-1',
            'name': 'Equipment',
            'type': 'tool',
            'parentId': 'group-1',
            'metadataJson': jsonEncode({
              'isExpanded': false,
              'custom': {'rate': 3},
            }),
          }),
          operation('INSERT_DEPENDENCY', {
            'predecessorTaskId': 'task-1',
            'successorTaskId': 'task-2',
            'type': 'contained',
            'lag': 4500,
          }),
        ];
        for (final write in writes) {
          await senderState.applyOperations([write], local: true);
          sender.send(write);
          final received = await observer.until((op) => op.type == write.type);
          await observerState.applyOperations([received]);
        }
        final liveRoot = (await observerState.computeMerkleTree()).root.hash;
        final deletes = [
          operation('DELETE_TASK', {'id': 'task-1'}),
          operation('DELETE_RESOURCE', {'id': 'resource-1'}),
          operation('DELETE_DEPENDENCY', {
            'predecessorTaskId': 'task-1',
            'successorTaskId': 'task-2',
          }),
        ];
        if (batchDelete) {
          final batch = operation('BATCH_UPDATE', {
            'operations': deletes.map((op) => op.toJson()).toList(),
          });
          await senderState.applyOperations([batch], local: true);
          sender.send(batch);
          final received = await observer.until(
            (op) => op.type == 'BATCH_UPDATE',
          );
          final ops = received.data['operations'] as List;
          expect(
            ops.map((op) => op['type']),
            unorderedEquals([
              'DELETE_TASK',
              'DELETE_RESOURCE',
              'DELETE_DEPENDENCY',
            ]),
          );
          await observerState.applyOperations([received]);
        } else {
          for (final deletion in deletes) {
            await senderState.applyOperations([deletion], local: true);
            sender.send(deletion);
            final received = await observer.until(
              (op) => op.type == deletion.type,
            );
            await observerState.applyOperations([received]);
            if (received.type == 'DELETE_TASK') {
              expect(received.data['name'], 'Full task');
              expect(received.data['custom'], {'externalId': 'custom-42'});
            } else if (received.type == 'DELETE_RESOURCE') {
              expect(received.data['name'], '');
              expect(received.data['parentId'], '');
              expect(received.data['custom'], isNull);
            } else {
              expect(received.data['lag'], 0);
            }
          }
        }
        final deletedRoot = (await observerState.computeMerkleTree()).root.hash;
        expect(deletedRoot, isNot(liveRoot));
        final cold = await newStore();
        final verifier = await connect(cold);
        final response = await verifier.merkleRoot();
        expect(deletedRoot, response.data['root']);
        expect(
          (await senderState.computeMerkleTree()).root.hash,
          response.data['root'],
        );
        expect(
          (await cold.computeMerkleTree()).root.hash,
          response.data['root'],
        );
        final stale = <Operation>[];
        for (var index = 0; index < writes.length; index++) {
          for (final timestamp in [
            writes[index].timestamp,
            deletes[index].timestamp,
          ]) {
            stale.add(
              Operation(
                type: [
                  'UPDATE_TASK',
                  'UPDATE_RESOURCE',
                  'UPDATE_DEPENDENCY',
                ][index],
                data: {
                  ...writes[index].data,
                  if (index < 2) 'name': 'STALE resurrection',
                  if (index == 2) 'type': 'finishToStart',
                  if (index == 2) 'lag': 0,
                },
                timestamp: timestamp,
                actorId: 'network-fixture',
              ),
            );
          }
        }
        await senderState.applyOperations(stale, local: true);
        if (batchDelete) {
          verifier.send(
            operation('BATCH_UPDATE', {
              'operations': stale.map((op) => op.toJson()).toList(),
            }),
          );
        } else {
          for (final op in stale) {
            verifier.send(op);
          }
        }
        // A subsequent broadcast on the same socket is a barrier: the server
        // consumes that socket's messages sequentially before forwarding it.
        verifier.send(
          operation('CURSOR_MOVE', {'integrationBarrier': 'stale-fence'}),
        );
        while (true) {
          final received = await observer.until((_) => true);
          if (received.type == 'CURSOR_MOVE' &&
              received.data['integrationBarrier'] == 'stale-fence') {
            break;
          }
          await observerState.applyOperations([received]);
        }
        final historicalRoot =
            (await senderState.computeMerkleTree()).root.hash;
        final hiddenTaskRow = (await dbs.first.query(
          "SELECT payload FROM canonical_protocol_state WHERE scope = 'local' AND entity_type = 'task' AND entity_id = 'task-1'",
        )).single;
        final hiddenTask = ProtocolTask.fromBuffer(
          base64Decode(hiddenTaskRow['payload'] as String),
        );
        expect(hiddenTask.isDeleted, isTrue);
        expect(hiddenTask.name, 'STALE resurrection');
        expect((await senderState.readState()).tasks, isEmpty);
        expect((await observerState.readState()).tasks, isEmpty);
        expect(
          (await observerState.computeMerkleTree()).root.hash,
          historicalRoot,
        );
        final staleReplay = await newStore();
        final staleVerifier = await connect(staleReplay);
        final staleResponse = await staleVerifier.merkleRoot();
        expect(staleResponse.data['root'], historicalRoot);
        expect(
          (await staleReplay.computeMerkleTree()).root.hash,
          historicalRoot,
        );
        expect(
          (await senderState.computeMerkleTree()).root.hash,
          historicalRoot,
        );

        final restores = [
          operation('UPDATE_TASK', {
            ...writes[0].data,
            'name': 'Restored task',
          }),
          operation('UPDATE_RESOURCE', {
            ...writes[1].data,
            'name': 'Restored resource',
          }),
          operation('UPDATE_DEPENDENCY', {...writes[2].data, 'lag': 9000}),
        ];
        if (batchDelete) {
          final restoration = operation('BATCH_UPDATE', {
            'operations': restores.map((op) => op.toJson()).toList(),
          });
          await senderState.applyOperations([restoration], local: true);
          sender.send(restoration);
          await observerState.applyOperations([
            await observer.until((op) => op.type == 'BATCH_UPDATE'),
          ]);
        } else {
          for (final restoration in restores) {
            await senderState.applyOperations([restoration], local: true);
            sender.send(restoration);
            await observerState.applyOperations([
              await observer.until((op) => op.type == restoration.type),
            ]);
          }
        }
        final restoredState = await newStore();
        final restoredVerifier = await connect(restoredState);
        final restoredResponse = await restoredVerifier.merkleRoot();
        expect(restoredResponse.data['root'], isNot(deletedRoot));
        expect(
          (await senderState.computeMerkleTree()).root.hash,
          restoredResponse.data['root'],
        );
        expect(
          (await observerState.computeMerkleTree()).root.hash,
          restoredResponse.data['root'],
        );
        expect(
          (await restoredState.computeMerkleTree()).root.hash,
          restoredResponse.data['root'],
        );

        final delayedHistory = operation('UPDATE_TASK', {
          'id': 'task-1',
          'notes': 'Historical notes delivered after reset',
        });
        final reset = operation('RESET_DATA', <String, dynamic>{});
        await senderState.applyOperations([reset], local: true);
        sender.send(reset);
        await observerState.applyOperations([
          await observer.until((op) => op.type == 'RESET_DATA'),
        ]);
        final delayedOperations = [
          delayedHistory,
          Operation(
            type: 'UPDATE_TASK',
            data: {'id': 'late-task', 'name': 'Unknown before reset'},
            timestamp: delayedHistory.timestamp,
            actorId: 'network-fixture',
          ),
          Operation(
            type: 'UPDATE_RESOURCE',
            data: {
              'id': 'late-resource',
              'name': 'Unknown resource',
              'type': 'tool',
            },
            timestamp: delayedHistory.timestamp,
            actorId: 'network-fixture',
          ),
          Operation(
            type: 'UPDATE_DEPENDENCY',
            data: {
              'predecessorTaskId': 'late-task',
              'successorTaskId': 'task-1',
              'type': 'contained',
              'lag': 4500,
            },
            timestamp: delayedHistory.timestamp,
            actorId: 'network-fixture',
          ),
        ];
        await senderState.applyOperations(delayedOperations, local: true);
        if (batchDelete) {
          sender.send(
            operation('BATCH_UPDATE', {
              'operations': delayedOperations.map((op) => op.toJson()).toList(),
            }),
          );
        } else {
          for (final delayed in delayedOperations) {
            sender.send(delayed);
          }
        }
        sender.send(
          operation('CURSOR_MOVE', {
            'integrationBarrier': 'post-reset-history',
          }),
        );
        while (true) {
          final received = await observer.until((_) => true);
          if (received.type == 'CURSOR_MOVE' &&
              received.data['integrationBarrier'] == 'post-reset-history') {
            break;
          }
          await observerState.applyOperations([received]);
        }
        expect((await observerState.readState()).tasks, isEmpty);
        expect((await observerState.readState()).resources, isEmpty);
        expect((await observerState.readState()).dependencies, isEmpty);
        final historyRows = await dbs[1].query(
          "SELECT payload FROM canonical_protocol_state WHERE entity_type = 'task' AND entity_id = 'task-1'",
        );
        expect(
          ProtocolTask.fromBuffer(
            base64Decode(historyRows.single['payload'] as String),
          ).notes,
          'Historical notes delivered after reset',
        );
        expect(
          (await observerState.computeMerkleTree()).root.hash,
          (await senderState.computeMerkleTree()).root.hash,
        );
        final newer = operation('UPDATE_TASK', {
          ...writes.first.data,
          'name': 'After reset',
          'notes': 'Historical notes delivered after reset',
        });
        await senderState.applyOperations([newer], local: true);
        sender.send(newer);
        await observerState.applyOperations([
          await observer.until((op) => op.type == 'UPDATE_TASK'),
        ]);
        final afterEdit = await newStore();
        final replayVerifier = await connect(afterEdit);
        final afterEditRoot = (await afterEdit.computeMerkleTree()).root.hash;
        expect(
          (await observerState.computeMerkleTree()).root.hash,
          afterEditRoot,
        );
        expect(
          (await senderState.computeMerkleTree()).root.hash,
          afterEditRoot,
        );
        replayVerifier.send(reset);
        final afterReplay = await replayVerifier.merkleRoot();
        expect(afterReplay.data['root'], afterEditRoot);
        final finalReplay = await newStore();
        await connect(finalReplay);
        expect(
          (await finalReplay.computeMerkleTree()).root.hash,
          afterEditRoot,
        );
      },
    );
  }

  test('public reconnect repairs a successfully handed off but lost same-value write', () async {
    final unique = DateTime.now().microsecondsSinceEpoch;
    final superuser = await post('/auth/login', {
      'username': 'superuser',
      'password': 'superuser',
    });
    final username = 'repair-admin-$unique';
    final tenant = await post('/api/admin/tenants', {
      'tenantName': 'repair-$unique',
      'adminUsername': username,
      'adminPassword': 'test-password',
    }, token: superuser['accessToken'] as String);
    final tenantId = tenant['tenantId'] as String;
    final auth = await post('/auth/login', {
      'username': username,
      'password': 'test-password',
    });
    final scope = jsonEncode([ws, tenantId]);
    final directory = await Directory.systemTemp.createTemp(
      'gantt-lost-handoff-',
    );
    final path = '${directory.path}/offline.sqlite';
    final peers = <Peer>[];
    final databases = <SqliteCrdt>[];
    GanttViewModel? client;
    addTearDown(() async {
      await client?.disposeAsync();
      for (final peer in peers) {
        await peer.close();
      }
      for (final db in databases.reversed) {
        await db.close();
      }
      await directory.delete(recursive: true);
    });
    Future<Peer> peer(ProtocolStateStore state) async {
      final connection = Peer(
        IOWebSocketChannel.connect(
          ws,
          headers: {'Authorization': 'Bearer ${auth['accessToken']}'},
        ),
      );
      peers.add(connection);
      await connection.channel.ready;
      connection.send(
        Operation(
          type: 'subscribe',
          data: {'channel': tenantId},
          timestamp: Hlc.zero,
          actorId: 'repair',
        ),
      );
      await connection.snapshot(state);
      return connection;
    }

    Operation operation(String type, Map<String, dynamic> data, int tick) =>
        Operation(
          type: type,
          data: data,
          timestamp: Hlc(millis: tick, counter: 0, nodeId: 'repair'),
          actorId: 'repair',
        );
    final baseTask = ProtocolTask(
      id: 'task',
      rowId: 'row',
      name: 'A',
      notes: 'Initial notes',
      start: '2026-11-20T00:00:00.000Z',
      end: '2026-11-21T00:00:00.000Z',
      lastUpdated: const Hlc(millis: 100, counter: 0, nodeId: 'repair').toString(),
    );
    baseTask.fieldTimestamps.addAll(baseTask.normalizedFieldTimestamps);
    final initial = operation(
      'UPDATE_TASK',
      ProtobufMapper.taskToJson(baseTask),
      100,
    );
    Map<String, dynamic> snapshot(
      String name,
      String notes,
      int nameClock,
      int notesClock,
      int presenceClock,
    ) {
      final task = baseTask.deepCopy()
        ..name = name
        ..notes = notes
        ..lastUpdated = Hlc(
          millis: presenceClock,
          counter: 0,
          nodeId: 'repair',
        ).toString();
      task.fieldTimestamps.addAll({
        'name': Hlc(millis: nameClock, counter: 0, nodeId: 'repair').toString(),
        'notes': Hlc(
          millis: notesClock,
          counter: 0,
          nodeId: 'repair',
        ).toString(),
        'isDeleted': Hlc(
          millis: presenceClock,
          counter: 0,
          nodeId: 'repair',
        ).toString(),
      });
      return ProtobufMapper.taskToJson(task);
    }

    final lost = operation(
      'UPDATE_TASK',
      snapshot('A', 'Initial notes', 200, 100, 200),
      200,
    );
    // This is an independent remote note edit: its name register still has
    // clock 100, so receiving it cannot implicitly repair the lost A200 write.
    final notes = operation(
      'UPDATE_TASK',
      snapshot('A', 'Shared notes', 100, 300, 300),
      300,
    );
    var db = await GanttDb.open(path);
    databases.add(db);
    var state = ProtocolStateStore(Future.value(db), scope: scope);
    await state.applyOperations(
      [initial, lost, notes],
      local: true,
      enqueue: true,
      bindScope: true,
    );
    expect(
      (await db.query('SELECT id FROM offline_queue WHERE is_deleted = 0')),
      hasLength(3),
    );
    // Model a socket accepting the packet and its queue row being removed,
    // followed by the packet never reaching the server.
    await db.execute('DELETE FROM offline_queue');
    final expectedRoot = (await state.computeMerkleTree()).root.hash;
    await db.close();
    databases.remove(db);

    final serverDb = await GanttDb.open(inMemoryDatabasePath);
    databases.add(serverDb);
    final serverState = ProtocolStateStore(Future.value(serverDb));
    final writer = await peer(serverState);
    final watcher = await peer(serverState);
    for (final update in [initial, notes]) {
      writer.send(update);
    }
    writer.send(
      operation('CURSOR_MOVE', {'integrationBarrier': 'seeded'}, 400),
    );
    while (true) {
      final received = await watcher.until((_) => true);
      if (received.type == 'CURSOR_MOVE') {
        break;
      }
      await serverState.applyOperations([received]);
    }
    expect((await serverState.readState()).tasks.single.name, 'A');
    expect(
      (await serverState.computeMerkleTree()).root.hash,
      isNot(expectedRoot),
      reason:
          'Equal values with different causal field clocks must trigger repair',
    );
    writer.send(
      operation(
        'UPDATE_TASK',
        snapshot('B', 'Initial notes', 150, 100, 150),
        150,
      ),
    );
    await serverState.applyOperations([
      await watcher.until((op) => op.type == 'UPDATE_TASK'),
    ]);
    expect((await serverState.readState()).tasks.single.name, 'B');

    Future<void> reopenAndConnect() async {
      db = await GanttDb.open(path);
      databases.add(db);
      state = ProtocolStateStore(Future.value(db), scope: scope);
      client = GanttViewModel(
        database: Future.value(db),
        useLocalDatabase: true,
      );
      await client!.initialized;
      expect(client!.allTasks.single.name, 'A');
      expect(
        (await db.query('SELECT id FROM offline_queue WHERE is_deleted = 0')),
        isEmpty,
      );
      await client!.connectSync(
        uri: base,
        tenantId: tenantId,
        username: username,
        password: 'test-password',
      );
    }

    await reopenAndConnect();
    final repaired = await writer.until(
      (op) => op.type == 'MERKLE_ROOT' && op.data['root'] == expectedRoot,
    );
    expect(repaired.data['root'], expectedRoot);
    expect(client!.allTasks.single.name, 'A');
    expect(client!.allTasks.single.notes, 'Shared notes');
    expect((await state.computeMerkleTree()).root.hash, expectedRoot);
    await client!.disconnectSync();
    await client!.disposeAsync();
    client = null;
    await db.close();
    databases.remove(db);
    await reopenAndConnect();
    expect(client!.allTasks.single.name, 'A');
    expect((await state.computeMerkleTree()).root.hash, expectedRoot);
    final coldDb = await GanttDb.open(inMemoryDatabasePath);
    databases.add(coldDb);
    final cold = ProtocolStateStore(Future.value(coldDb));
    final verifier = await peer(cold);
    expect((await verifier.merkleRoot()).data['root'], expectedRoot);
    expect((await cold.readState()).tasks.single.name, 'A');
    expect((await cold.readState()).tasks.single.notes, 'Shared notes');
    expect((await cold.computeMerkleTree()).root.hash, expectedRoot);
  });

  test('server restarts with the persisted synchronization clocks', () async {
    server!.kill();
    await server!.exitCode;
    await startServer();
    final response = await post('/auth/login', {
      'username': 'superuser',
      'password': 'superuser',
    });
    expect(response['accessToken'], isA<String>());
  });
}
