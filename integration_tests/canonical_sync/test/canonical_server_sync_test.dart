import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:async/async.dart';
import 'package:example/data/local/protocol_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
        'data': json['data'] ?? <String, dynamic>{},
        'timestamp': json['timestamp'] ?? Hlc.zero.toString(),
        'actorId': json['actorId'] ?? '',
      });
      if (predicate(op)) return op;
    }
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
  setUpAll(() async {
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
  });
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
          final db = await SqliteCrdt.openInMemory(
            version: 1,
            onCreate: (db, version) async {},
          );
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
              expect(received.data['name'], 'Equipment');
              expect(received.data['custom'], {'rate': 3});
            } else {
              expect(received.data['lag'], 4500);
            }
          }
        }
        final deletedRoot = (await observerState.computeMerkleTree()).root.hash;
        expect(deletedRoot, isNot(liveRoot));
        final cold = await newStore();
        final verifier = await connect(cold);
        verifier.send(operation('GET_MERKLE_ROOT', <String, dynamic>{}));
        final response = await verifier.until((op) => op.type == 'MERKLE_ROOT');
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
        expect(
          (await observerState.computeMerkleTree()).root.hash,
          deletedRoot,
        );
        final staleReplay = await newStore();
        final staleVerifier = await connect(staleReplay);
        staleVerifier.send(operation('GET_MERKLE_ROOT', <String, dynamic>{}));
        final staleResponse = await staleVerifier.until(
          (op) => op.type == 'MERKLE_ROOT',
        );
        expect(staleResponse.data['root'], deletedRoot);
        expect((await staleReplay.computeMerkleTree()).root.hash, deletedRoot);
        expect((await senderState.computeMerkleTree()).root.hash, deletedRoot);

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
        restoredVerifier.send(
          operation('GET_MERKLE_ROOT', <String, dynamic>{}),
        );
        final restoredResponse = await restoredVerifier.until(
          (op) => op.type == 'MERKLE_ROOT',
        );
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

        final reset = operation('RESET_DATA', <String, dynamic>{});
        await senderState.applyOperations([reset], local: true);
        sender.send(reset);
        await observerState.applyOperations([
          await observer.until((op) => op.type == 'RESET_DATA'),
        ]);
        final newer = operation('UPDATE_TASK', {
          ...writes.first.data,
          'name': 'After reset',
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
        final afterReplay = await replayVerifier.until(
          (op) => op.type == 'MERKLE_ROOT',
        );
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
}
