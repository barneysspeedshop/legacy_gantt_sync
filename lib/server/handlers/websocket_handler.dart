import 'dart:async';
import 'dart:convert';

import 'package:legacy_gantt_sync/server/services/merkle_service.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart' hide Hlc;
import 'package:legacy_gantt_sync/server/utils/hlc.dart';
import 'package:legacy_gantt_sync/server/models/client_info.dart';
import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:legacy_gantt_sync/server/services/client_service.dart';
import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_sync/server/services/operation_service.dart';
import 'package:legacy_gantt_sync/server/services/pub_sub_service.dart';
import 'package:legacy_gantt_sync/server/constants/protocol_constants.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:postgres_crdt/postgres_crdt.dart' show CrdtExecutor;

class WebSocketHandler {
  final AuthService authService;
  final CrdtService crdtService;
  final OperationService operationService;
  final ClientService clientService;
  final PubSubService pubSubService;
  final MerkleService merkleService;

  WebSocketHandler({
    required this.authService,
    required this.crdtService,
    required this.operationService,
    required this.clientService,
    required this.pubSubService,
    required this.merkleService,
  });

  FutureOr<Response> handleRequest(Request request) {
    final userId = request.context['auth.userId'] as String?;
    final tenantId = request.context['auth.tenantId'] as String?;
    final role = request.context['auth.role'] as String?;

    if (userId == null) {
      return Response.forbidden('Auth context missing');
    }

    final handler = webSocketHandler((webSocket, _) {
      _handleSocket(webSocket, userId, tenantId, role ?? 'user');
    }, pingInterval: const Duration(seconds: 20));

    return handler(request);
  }

  void _handleSocket(
    WebSocketChannel webSocket,
    String userId,
    String? tenantId,
    String role,
  ) async {
    final channel = webSocket;
    final connectionId = const Uuid().v4();
    final tId = tenantId ?? 'system';

    final clientInfo = ClientInfo(userId, tId, role, connectionId);

    _initializeSession(channel, clientInfo);

    try {
      await for (final rawMessage in channel.stream) {
        try {
          final envelope = ProtocolMessage.fromBuffer(rawMessage as List<int>);
          final jsonMap = ProtobufMapper.toJson(envelope);
          final type = jsonMap['type'] as String?;

          if (type == 'subscribe') {
            await _handleSubscribe(channel, clientInfo, jsonMap);
          } else {
            await _handleOperation(channel, clientInfo, type, jsonMap);
          }
        } catch (e, st) {
          JsonLogger.error('MSG_PROCESSING_ERROR', {
            'error': e.toString(),
            'stackTrace': st.toString(),
          });
          _sendJsonAsProtobuf(channel, {'error': 'Invalid message format'});
        }
      }
    } catch (e, st) {
      JsonLogger.error('STREAM_ERROR', {
        'error': e.toString(),
        'stackTrace': st.toString(),
      });
    } finally {
      _cleanupSession(channel, clientInfo);
    }
  }

  void _initializeSession(dynamic channel, ClientInfo clientInfo) {
    clientService.addClient(channel, clientInfo);
    JsonLogger.info('CLIENT_CONNECTED', {
      'user_id': clientInfo.userId,
      'tenant_id': clientInfo.tenantId,
    });

    pubSubService.publish(
      'tenant_users_${clientInfo.tenantId}',
      jsonEncode({
        'type': 'USER_LIST_UPDATE',
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
      }),
    );

    pubSubService.publish(
      'admin_updates',
      jsonEncode({
        'type': 'TENANT_LIST_UPDATE',
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
      }),
    );

    _sendJsonAsProtobuf(channel, {
      'type': 'AUTH_SUCCESS',
      'userId': clientInfo.userId,
      'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
    });
  }

  void _cleanupSession(dynamic channel, ClientInfo clientInfo) {
    clientService.removeClient(channel);
    JsonLogger.info('CLIENT_DISCONNECTED', {
      'user_id': clientInfo.userId,
      'tenant_id': clientInfo.tenantId,
    });

    pubSubService.publish(
      'tenant_users_${clientInfo.tenantId}',
      jsonEncode({
        'type': 'USER_LIST_UPDATE',
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
      }),
    );

    pubSubService.publish(
      'admin_updates',
      jsonEncode({
        'type': 'TENANT_LIST_UPDATE',
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
      }),
    );
  }

  Future<void> _handleSubscribe(
    dynamic channel,
    ClientInfo clientInfo,
    Map<String, dynamic> jsonMap,
  ) async {
    final channelName = jsonMap['channel'] as String?;
    final lastSynced = jsonMap['lastSyncedTimestamp']?.toString();

    if (channelName == null || channelName.isEmpty) {
      // This should be unreachable given the message type
      return;
    }

    JsonLogger.info('SUBSCRIBE_ATTEMPT', {
      'user_id': clientInfo.userId,
      'tenant_id': clientInfo.tenantId,
      'requested_channel': channelName,
      'last_synced': lastSynced,
    });

    // 1. Admin Updates
    if (channelName == ProtocolConstants.channelAdminUpdates) {
      if (clientInfo.role != 'superuser') {
        _sendError(channel, 'Forbidden channel');
        return;
      }
      _approveSubscription(channel, clientInfo, channelName);
      return;
    }

    // 2. Tenant Users
    if (channelName.startsWith(ProtocolConstants.channelTenantUsersPrefix)) {
      final targetTenantId = channelName.replaceFirst(
        ProtocolConstants.channelTenantUsersPrefix,
        '',
      );
      if (clientInfo.role == 'superuser' ||
          clientInfo.tenantId == targetTenantId) {
        _approveSubscription(channel, clientInfo, channelName);
        return;
      }
      _sendError(channel, 'Forbidden channel');
      return;
    }

    // 3. Tenant Data Channel (The main one)
    if (channelName == clientInfo.tenantId) {
      _approveSubscription(channel, clientInfo, channelName);

      try {
        await crdtService.streamSyncData(
          clientInfo.tenantId,
          lastSynced: lastSynced,
          onEvent: (event) => _sendJsonAsProtobuf(channel, event),
        );
      } catch (e) {
        JsonLogger.error('SYNC_ERROR', {
          'error': e.toString(),
          'tenant_id': clientInfo.tenantId,
        });
        _sendJsonAsProtobuf(channel, {'error': 'Sync failed'});
      }
      return;
    }

    // 4. Unknown
    JsonLogger.warn('UNKNOWN_CHANNEL', {'channel': channelName});
    _sendError(channel, 'Forbidden channel');
  }

  // Validate HLC drift to prevent time travel
  String _validateTimestamp(String? clientTimestamp, String userId) {
    // If missing, assign server time (Sovereign fallback)
    // We construct a server-side HLC.
    final serverNow = DateTime.now().millisecondsSinceEpoch;

    if (clientTimestamp == null) {
      return Hlc(millis: serverNow, counter: 0, nodeId: 'server').toString();
    }

    try {
      // 1. Parse the HLC to get the physical time
      final hlc = Hlc.parse(clientTimestamp);

      // 2. Calculate Drift
      final diff = hlc.millis - serverNow;
      const int maxDrift = 60000; // 60 seconds

      // 3. The Bouncer Check
      if (diff > maxDrift) {
        throw FormatException(
          'CLOCK_SKEW: Timestamp is $diff ms in the future.',
        );
      }

      // 4. Return original if valid
      return clientTimestamp;
    } catch (e) {
      // If parsing fails, it's garbage data. Reject it.
      JsonLogger.warn('INVALID_HLC_TIMESTAMP', {
        'error': e.toString(),
        'timestamp': clientTimestamp,
        'userId': userId,
      });
      throw FormatException('INVALID_HLC: ${e.toString()}');
    }
  }

  Future<void> _handleOperation(
    dynamic channel,
    ClientInfo clientInfo,
    String? type,
    Map<String, dynamic> jsonMap,
  ) async {
    final data = jsonMap['data'] ?? {};
    String timestamp;

    try {
      // jsonMap['timestamp'] comes as String from ProtocolMessage extraction logic if used,
      // but here we are decoding raw JSON so it might be String directly.
      timestamp = _validateTimestamp(
        jsonMap['timestamp']?.toString(),
        clientInfo.userId,
      );
    } catch (e) {
      JsonLogger.warn('OP_REJECTED_ERROR', {
        'error': e.toString(),
        'user': clientInfo.userId,
      });
      _sendJsonAsProtobuf(channel, {
        'type': 'ERROR',
        'error': 'INVALID_TIMESTAMP: $e',
      });
      return;
    }

    final actorId = clientInfo.userId;
    final targetChannel = clientInfo.tenantId;

    if (type == ProtocolConstants.optimizeSchedule) {
      _sendJsonAsProtobuf(channel, {
        'type': 'ERROR',
        'error': 'Scheduling is experimental and not implemented',
      });
      return;
    }

    if (type == ProtocolConstants.batchUpdate) {
      await _handleBatchUpdate(
        clientInfo,
        data,
        timestamp,
        actorId,
        targetChannel,
      );
      return;
    }

    // Check last_reset_at to prevent stale data injection
    if (type != ProtocolConstants.resetData &&
        type != ProtocolConstants.cursorMove &&
        type != ProtocolConstants.presenceUpdate &&
        type != ProtocolConstants.ghostUpdate) {
      try {
        final resetMeta = await crdtService.query(
          targetChannel,
          'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ?',
          [targetChannel],
        );
        if (resetMeta.isNotEmpty) {
          final lastResetAt = resetMeta.first['last_reset_at'] as String?;
          if (lastResetAt != null && timestamp.compareTo(lastResetAt) <= 0) {
            JsonLogger.warn('OP_STALE_REJECTED', {
              'user': actorId,
              'type': type,
              'timestamp': timestamp,
              'lastResetAt': lastResetAt,
            });
            return; // completely ignore and don't broadcast
          }
        }
      } catch (e) {
        JsonLogger.error('RESET_CHECK_ERROR', {'error': e.toString()});
      }
    }

    // Single Operation
    final isDbOp = const {
      ProtocolConstants.insertTask,
      ProtocolConstants.updateTask,
      ProtocolConstants.deleteTask,
      ProtocolConstants.insertDependency,
      ProtocolConstants.updateDependency,
      ProtocolConstants.deleteDependency,
      ProtocolConstants.insertResource,
      ProtocolConstants.updateResource,
      ProtocolConstants.deleteResource,
      ProtocolConstants.resetData,
      ProtocolConstants.optimizeSchedule,
    }.contains(type);

    final isEphemeral = const {
      ProtocolConstants.cursorMove,
      ProtocolConstants.ghostUpdate,
      ProtocolConstants.presenceUpdate,
    }.contains(type);

    List<Map<String, dynamic>> sideEffects = [];
    Map<String, dynamic>? deletionSnapshot;
    if (isDbOp) {
      try {
        await crdtService.runTransaction(clientInfo.tenantId, (txn) async {
          sideEffects = await operationService.applySingleOperation(
            txn,
            clientInfo.tenantId,
            type!,
            data,
            timestamp,
          );
          if (_deletionTypes.contains(type)) {
            deletionSnapshot = await _readDeletionSnapshot(
              txn,
              clientInfo.tenantId,
              type,
              data as Map<String, dynamic>,
            );
          }
        });
      } catch (e) {
        JsonLogger.error('DB_WRITE_ERROR', {
          'error': e.toString(),
          'tenant_id': clientInfo.tenantId,
        });
        return; // Don't propagate failed operations
      }
    } else if (type == 'GET_MERKLE_ROOT') {
      final root = await merkleService.getMerkleRoot(clientInfo.tenantId);
      _sendJsonAsProtobuf(channel, {
        'type': 'MERKLE_ROOT',
        'data': {'root': root},
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
      });
      return;
    } else if (type == 'GET_MERKLE_NODE') {
      final prefix = data['prefix'] as String? ?? '';
      final children = await merkleService.getMerkleNodeChildren(
        clientInfo.tenantId,
        prefix,
      );
      _sendJsonAsProtobuf(channel, {
        'type': 'MERKLE_NODE',
        'data': {'prefix': prefix, 'children': children},
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
      });
      return;
    } else if (type == 'GET_ENTITIES_IN_RANGE') {
      final prefix = data['prefix'] as String? ?? '';
      final operations = await merkleService.getEntitiesInPrefix(
        clientInfo.tenantId,
        prefix,
      );
      // We transmit them back as a BATCH_UPDATE so the client's CRDT engine processes them
      _sendJsonAsProtobuf(channel, {
        'type': 'BATCH_UPDATE',
        'channel': prefix,
        'data': {'operations': operations, 'merklePrefix': prefix},
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
      });
      return;
    } else if (!isEphemeral) {
      JsonLogger.info('UNKNOWN_OPERATION', {'type': type, 'data': data});
    }

    // Broadcast Side Effects
    if (sideEffects.isNotEmpty) {
      _broadcastBatch(targetChannel, clientInfo.connectionId, sideEffects);
    }

    // Broadcast Original Operation
    if ((isDbOp || isEphemeral) &&
        (!_deletionTypes.contains(type) || deletionSnapshot != null)) {
      pubSubService.publish(
        targetChannel,
        jsonEncode({
          'originConnectionId': clientInfo.connectionId,
          'type': type,
          'data': deletionSnapshot?['data'] ?? data,
          'timestamp': deletionSnapshot?['timestamp'] ?? timestamp,
          'actorId': actorId,
        }),
      );
    }

    if (isDbOp) {
      final root = await merkleService.getMerkleRoot(clientInfo.tenantId);
      pubSubService.publish(
        targetChannel,
        jsonEncode({
          'originConnectionId': 'server-sync',
          'type': 'MERKLE_ROOT',
          'data': {'root': root},
          'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
          'actorId': 'server-sync',
        }),
      );
    }
  }

  Future<void> _handleBatchUpdate(
    ClientInfo clientInfo,
    Map<String, dynamic> data,
    String batchTimestamp,
    String actorId,
    String targetChannel,
  ) async {
    final ops = data['operations'] as List;
    JsonLogger.info('BATCH_UPDATE_RECEIVED', {
      'count': ops.length,
      'user_id': clientInfo.userId,
      'tenant_id': clientInfo.tenantId,
    });

    String? lastResetAt;
    try {
      final resetMeta = await crdtService.query(
        targetChannel,
        'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ?',
        [targetChannel],
      );
      if (resetMeta.isNotEmpty) {
        lastResetAt = resetMeta.first['last_reset_at'] as String?;
      }
    } catch (e) {
      JsonLogger.error('BATCH_RESET_CHECK_ERROR', {'error': e.toString()});
    }

    // We must sanitize the operations list for the PubSub broadcast
    final sanitizedOps = <Map<String, dynamic>>[];

    const batchSize = 500;
    for (var i = 0; i < ops.length; i += batchSize) {
      final chunk = ops.sublist(
        i,
        (i + batchSize < ops.length) ? i + batchSize : ops.length,
      );

      await crdtService.runTransaction(clientInfo.tenantId, (txn) async {
        final groupedOps = <Map<String, dynamic>>[];
        final bulkTasks = <Map<String, dynamic>>[];

        void flushBulkTasks() {
          if (bulkTasks.isNotEmpty) {
            // Found a bulk group!
            // We use the timestamp of the LAST item in the bulk group as the operation timestamp,
            // or we could use the batchTimestamp. Given side-effects usually share the same timestamp,
            // using the last one is safe enough for HLC monotonicity.
            final lastTs = bulkTasks.last['timestamp'] as String;

            groupedOps.add({
              'type': 'BULK_INSERT_TASK',
              'data': {
                'tasks': List<Map<String, dynamic>>.from(
                  bulkTasks.map((op) => op['data']),
                ),
              },
              'timestamp': lastTs,
            });
            bulkTasks.clear();
          }
        }

        for (final op in chunk) {
          final opMap = op as Map<String, dynamic>;
          String innerTimestamp;
          try {
            innerTimestamp = _validateTimestamp(
              opMap['timestamp']?.toString(),
              clientInfo.userId,
            );
          } catch (e) {
            JsonLogger.warn('BATCH_OP_SKIPPED', {
              'error': e.toString(),
              'op': opMap,
            });
            continue;
          }

          final type = opMap['type'];
          if (lastResetAt != null &&
              type != ProtocolConstants.resetData &&
              type != ProtocolConstants.cursorMove &&
              type != ProtocolConstants.presenceUpdate &&
              type != ProtocolConstants.ghostUpdate) {
            if (innerTimestamp.compareTo(lastResetAt) <= 0) {
              JsonLogger.warn('BATCH_OP_STALE_REJECTED', {
                'user': clientInfo.userId,
                'type': type,
                'timestamp': innerTimestamp,
                'lastResetAt': lastResetAt,
              });
              continue;
            }
          }

          final finalOp = Map<String, dynamic>.from(opMap);
          finalOp['timestamp'] = innerTimestamp;
          sanitizedOps.add(
            finalOp,
          ); // Still sanitize individually for broadcast

          // Grouping Logic
          if (type == ProtocolConstants.insertTask) {
            // Add to bulk buffer, keeping the timestamp inside just in case
            finalOp['data']['timestamp'] =
                innerTimestamp; // Ensure data has timestamp if needed??
            // Actually handler uses passed timestamp.
            // We'll store the whole op wrapper to extract data later
            bulkTasks.add(finalOp);
          } else {
            // Non-insert-task op. Flush any pending bulk buffer first.
            flushBulkTasks();
            groupedOps.add(finalOp);
          }
        }
        flushBulkTasks(); // Flush any remaining at end of chunk

        // Process the grouped list
        for (final op in groupedOps) {
          try {
            if (op['type'] == null) continue;
            final originalBulkTasks = op['type'] == 'BULK_INSERT_TASK'
                ? List<Map<String, dynamic>>.from(op['data']['tasks'] as List)
                : null;
            await operationService.applySingleOperation(
              txn,
              clientInfo.tenantId,
              op['type'] as String,
              op['data'] as Map<String, dynamic>,
              op['timestamp'] as String,
            );
            if (originalBulkTasks != null) {
              final accepted = Set<Map<String, dynamic>>.identity()
                ..addAll(
                  (op['data']['tasks'] as List).cast<Map<String, dynamic>>(),
                );
              final rejected = Set<Map<String, dynamic>>.identity()
                ..addAll(
                  originalBulkTasks.where((task) => !accepted.contains(task)),
                );
              sanitizedOps.removeWhere(
                (operation) => rejected.contains(operation['data']),
              );
            }
            if (_deletionTypes.contains(op['type'])) {
              final snapshot = await _readDeletionSnapshot(
                txn,
                clientInfo.tenantId,
                op['type'] as String,
                op['data'] as Map<String, dynamic>,
              );
              if (snapshot == null) {
                sanitizedOps.remove(op);
              } else {
                op['data'] = snapshot['data'];
                op['timestamp'] = snapshot['timestamp'];
              }
            }
          } on StaleTombstoneOperation {
            sanitizedOps.remove(op);
          } catch (e, st) {
            JsonLogger.error('BATCH_OP_PROCESSING_ERROR', {
              'error': e.toString(),
              'stackTrace': st.toString(),
              'op': op,
            });
            rethrow;
          }
        }
      });
    }

    // Broadcast the SANITIZED operations
    final broadcastData = Map<String, dynamic>.from(data);
    broadcastData['operations'] = sanitizedOps;

    pubSubService.publish(
      targetChannel,
      jsonEncode({
        'originConnectionId': clientInfo.connectionId,
        'type': ProtocolConstants.batchUpdate,
        'data': broadcastData,
        'timestamp': batchTimestamp,
        'actorId': actorId,
      }),
    );

    final root = await merkleService.getMerkleRoot(targetChannel);
    pubSubService.publish(
      targetChannel,
      jsonEncode({
        'originConnectionId': 'server-sync',
        'type': 'MERKLE_ROOT',
        'data': {'root': root},
        'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
        'actorId': 'server-sync',
      }),
    );
  }

  void _approveSubscription(
    dynamic channel,
    ClientInfo clientInfo,
    String requestedChannel,
  ) {
    clientService.subscribe(channel, requestedChannel);
    JsonLogger.info('SUBSCRIBE_SUCCESS', {
      'user_id': clientInfo.userId,
      'channel': requestedChannel,
    });
    _sendJsonAsProtobuf(channel, {
      'type': 'SUBSCRIBE_SUCCESS',
      'channel': requestedChannel,
    });
  }

  void _sendError(dynamic channel, String message) {
    _sendJsonAsProtobuf(channel, {'error': message});
  }

  void _broadcastBatch(
    String targetChannel,
    String originConnectionId,
    List<Map<String, dynamic>> operations,
  ) {
    const int chunkSize = 50;
    for (var i = 0; i < operations.length; i += chunkSize) {
      final end = (i + chunkSize < operations.length)
          ? i + chunkSize
          : operations.length;
      final chunk = operations.sublist(i, end);

      pubSubService.publish(
        targetChannel,
        jsonEncode({
          'originConnectionId': originConnectionId,
          'type': ProtocolConstants.batchUpdate,
          'data': {'operations': chunk},
          'timestamp': Hlc.fromDate(DateTime.now(), 'server-ws').toString(),
          'actorId': 'server-solver',
        }),
      );
    }
  }

  static const _deletionTypes = {
    ProtocolConstants.deleteTask,
    ProtocolConstants.deleteResource,
    ProtocolConstants.deleteDependency,
  };

  // Read within the write transaction so the broadcast contains the same
  // tombstone content and clock as snapshots and server Merkle hashing.
  Future<Map<String, dynamic>?> _readDeletionSnapshot(
    CrdtExecutor transaction,
    String tenantId,
    String type,
    Map<String, dynamic> data,
  ) async {
    final String sql;
    final List<Object?> parameters;
    switch (type) {
      case ProtocolConstants.deleteTask:
        sql = 'SELECT * FROM tasks WHERE tenant_id = ? AND id = ?';
        parameters = [tenantId, data['id'] ?? data['taskId']];
      case ProtocolConstants.deleteResource:
        sql = 'SELECT * FROM resources WHERE tenant_id = ? AND id = ?';
        parameters = [tenantId, data['id'] ?? data['resourceId']];
      case ProtocolConstants.deleteDependency:
        sql =
            'SELECT * FROM dependencies WHERE tenant_id = ? AND predecessor_task_id = ? AND successor_task_id = ?';
        parameters = [
          tenantId,
          data['predecessorTaskId'],
          data['successorTaskId'],
        ];
      default:
        return null;
    }
    final rows = await transaction.query(sql, parameters);
    if (rows.isEmpty) return null;
    final row = Map<String, dynamic>.from(rows.single);
    return switch (type) {
      ProtocolConstants.deleteTask => crdtService.formatTaskOperation(row),
      ProtocolConstants.deleteResource => crdtService.formatResourceOperation(
        row,
      ),
      ProtocolConstants.deleteDependency =>
        crdtService.formatDependencyOperation(row),
      _ => null,
    };
  }

  void _sendJsonAsProtobuf(dynamic channel, Map<String, dynamic> json) {
    channel.sink.add(ProtobufMapper.toProtobuf(json).writeToBuffer());
  }
}
