import 'dart:convert';
import 'dart:io';

// import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:legacy_gantt_sync/middleware/auth_middleware.dart';
import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:legacy_gantt_sync/models/models.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';

// Maps Channel ID -> List of Clients
final Map<String, List<WebSocketChannel>> _channels = {};
// Cached CRDT instances per tenant
final Map<String, PostgresCrdt> _tenantCrdts = {};
// In-flight initialization futures to prevent race conditions
final Map<String, Future<PostgresCrdt>> _crdtFutures = {};

// We need to associate metadata with the socket
class ClientInfo {
  final String userId;
  final String tenantId;
  String? currentChannel;

  ClientInfo(this.userId, this.tenantId);
}

final Map<WebSocketChannel, ClientInfo> _clientInfos = {};

Future<PostgresCrdt> _getTenantCrdt(String tenantId) {
  if (_tenantCrdts.containsKey(tenantId)) {
    return Future.value(_tenantCrdts[tenantId]!);
  }

  return _crdtFutures.putIfAbsent(tenantId, () async {
    try {
      // Sanitize tenantId to prevent SQL injection (simple check)
      final crdt = await PostgresCrdt.open(
        Platform.environment['DB_NAME'] ?? 'legacy_gantt',
        host: Platform.environment['DB_HOST'] ?? 'localhost',
        port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
        username: Platform.environment['DB_USER'] ?? 'dart_user',
        password: Platform.environment['DB_PASS'] ?? 'dart_password',
        sslMode: SslMode.disable, // Local postgres doesn't have SSL configured usually
      );

      final schema = '"$tenantId"';

      await crdt.execute('CREATE SCHEMA IF NOT EXISTS $schema');
      await crdt.execute('SET search_path TO $schema');

      // Create base tables for Gantt
      await crdt.execute('''
    CREATE TABLE IF NOT EXISTS "$tenantId".tasks (
      id TEXT PRIMARY KEY,
      name TEXT,
      gantt_type TEXT,
      start_date BIGINT,
      end_date BIGINT,
      parent_id TEXT,
      hlc TEXT NOT NULL DEFAULT '',
      node_id TEXT NOT NULL DEFAULT '',
      modified TEXT NOT NULL DEFAULT '',
      is_deleted BOOLEAN NOT NULL DEFAULT FALSE
    )
    ''');
      // Migration for existing tables
      try {
        // Rename column if it exists as 'type'
        await crdt.execute('ALTER TABLE "$tenantId".tasks RENAME COLUMN type TO gantt_type');
      } catch (_) {
        // Ignore if column doesn't exist or is already renamed
      }
      try {
        // Add if missing (for new tables or if rename failed/skipped)
        await crdt.execute('ALTER TABLE "$tenantId".tasks ADD COLUMN IF NOT EXISTS gantt_type TEXT');
      } catch (_) {}

      await crdt.execute('''
    CREATE TABLE IF NOT EXISTS "$tenantId".dependencies (
      predecessor_task_id TEXT NOT NULL,
      successor_task_id TEXT NOT NULL,
      dependency_type TEXT NOT NULL DEFAULT 'finishToStart',
      hlc TEXT NOT NULL DEFAULT '',
      node_id TEXT NOT NULL DEFAULT '',
      modified TEXT NOT NULL DEFAULT '',
      is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
      PRIMARY KEY (predecessor_task_id, successor_task_id)
    )
    ''');

      // Migration for dependencies table
      try {
        // Rename column if it exists as 'type'
        await crdt.execute('ALTER TABLE "$tenantId".dependencies RENAME COLUMN type TO dependency_type');
      } catch (_) {
        // Ignore if column doesn't exist or is already renamed
      }

      // Create resources table
      await crdt.execute('''
    CREATE TABLE IF NOT EXISTS "$tenantId".resources (
      id TEXT PRIMARY KEY,
      name TEXT,
      parent_id TEXT,
      gantt_type TEXT,
      is_expanded BOOLEAN NOT NULL DEFAULT TRUE,
      hlc TEXT NOT NULL DEFAULT '',
      node_id TEXT NOT NULL DEFAULT '',
      modified TEXT NOT NULL DEFAULT '',
      is_deleted BOOLEAN NOT NULL DEFAULT FALSE
    )
    ''');
      try {
        // Add if missing
        await crdt.execute('ALTER TABLE "$tenantId".dependencies ADD COLUMN IF NOT EXISTS dependency_type TEXT DEFAULT \'finishToStart\'');
      } catch (_) {}

      try {
        await crdt.execute('ALTER TABLE "$tenantId".resources ADD COLUMN IF NOT EXISTS gantt_type TEXT');
      } catch (_) {}

      _tenantCrdts[tenantId] = crdt;
      JsonLogger.info('CRDT_INIT', {'tenant_id': tenantId});

      return crdt;
    } finally {
      // Keep the future in map? No, once satisfied, if we remove it, future calls hit _tenantCrdts.
      // But we must populate _tenantCrdts BEFORE removing.
      _crdtFutures.remove(tenantId);
    }
  });
}

Middleware corsHeaders() {
  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS, PATCH',
            'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization, X-Requested-With',
          },
        );
      }
      final response = await innerHandler(request);
      return response.change(
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS, PATCH',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization, X-Requested-With',
        },
      );
    };
  };
}

void main(List<String> args) async {
  final port = int.parse(Platform.environment['LEGACY_GANTT_SYNC_PORT'] ?? '8080');
  final jwtSecret = Platform.environment['JWT_SECRET'] ?? 'default_secret'; // WARN: Use strong secret in prod

  // 1. Init Auth DB Connection
  final authDbConnection = await Connection.open(
    Endpoint(
      host: Platform.environment['DB_HOST'] ?? 'localhost',
      database: Platform.environment['DB_NAME'] ?? 'legacy_gantt',
      username: Platform.environment['DB_USER'] ?? 'dart_user',
      password: Platform.environment['DB_PASS'] ?? 'dart_password',
      port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );

  final authService = AuthService(authDbConnection, jwtSecret);
  await authService.init();

  final app = Router();

  // --- Auth Endpoints ---
  app.post('/auth/register', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final tenant = await authService.registerTenant(body['tenantName'], body['adminUsername'], body['adminPassword']);
      return Response.ok(jsonEncode({'tenantId': tenant.id, 'message': 'Tenant registered successfully'}));
    } catch (e) {
      JsonLogger.error('REGISTER_ERROR', {'error': e.toString()});
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  app.post('/auth/login', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final tokens = await authService.login(body['username'], body['password']);
      return Response.ok(jsonEncode(tokens));
    } catch (e) {
      JsonLogger.warn('LOGIN_FAILED', {'error': e.toString()});
      return Response.forbidden(jsonEncode({'error': 'Invalid credentials'}));
    }
  });

  // --- Admin Endpoints (RBAC) ---
  final apiRouter = Router();

  // Add User (Tenant Admin)
  apiRouter.post('/users', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final creatorTenantId = request.context['auth.tenantId'] as String;

    // Security check: cannot create users for other tenants
    // Ideally user creation endpoint shouldn't take tenantId, it infers from creator.
    // But if we want superusers to create users anywhere, we need to check.
    // For now, simplify: create user in YOUR tenant.

    try {
      final user = await authService.registerUser(
        creatorTenantId,
        body['username'],
        body['password'],
        'user', // Default role
      );
      return Response.ok(jsonEncode({'userId': user.id, 'message': 'User created'}));
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // Revoke User (Tenant Admin)
  apiRouter.delete('/users/<userId>', (Request request, String userId) async {
    // TODO: Check if user belongs to tenant of the admin
    try {
      await authService.revokeUser(userId);
      return Response.ok('User revoked');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

  // Revoke Tenant (Superuser)
  // Define separate handler or check role inside

  app.mount(
    '/api/',
    const Pipeline()
        .addMiddleware(roleMiddleware(['tenant_admin', 'superuser'])) // Default minimal protection
        .addHandler(apiRouter.call),
  );

  // --- WebSocket ---
  app.get('/ws', (Request request) async {
    // Auth handled by middleware
    final userId = request.context['auth.userId'] as String;
    final tenantId = request.context['auth.tenantId'] as String;
    // final role = request.context['auth.role'] as String;

    final handler = webSocketHandler((webSocket, _) {
      final channel = webSocket;
      final clientInfo = ClientInfo(userId, tenantId);
      _clientInfos[channel] = clientInfo;

      JsonLogger.info('CLIENT_CONNECTED', {'user_id': userId, 'tenant_id': tenantId});

      () async {
        try {
          await for (final rawMessage in channel.stream) {
            try {
              final jsonMap = jsonDecode(rawMessage as String) as Map<String, dynamic>;
              final type = jsonMap['type'] as String?;

              ProtocolMessage? message;
              if (type == 'subscribe') {
                message = ProtocolMessage.subscribe(type: 'subscribe', channel: jsonMap['channel'] as String);
              } else {
                message = ProtocolMessage.operation(
                  type: type ?? 'unknown',
                  data: jsonMap['data'] ?? {},
                  timestamp: jsonMap['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
                  actorId: userId,
                );
              }

              await message.map(
                subscribe: (msg) async {
                  final requestedChannel = msg.channel;
                  JsonLogger.info('SUBSCRIBE_ATTEMPT', {'user_id': userId, 'tenant_id': tenantId, 'requested_channel': requestedChannel});

                  // STRICT TENANT ISOLATION
                  if (requestedChannel == tenantId) {
                    if (clientInfo.currentChannel != null) {
                      _channels[clientInfo.currentChannel]?.remove(channel);
                    }

                    clientInfo.currentChannel = requestedChannel;
                    _channels.putIfAbsent(requestedChannel, () => []).add(channel);

                    JsonLogger.info('SUBSCRIBE_SUCCESS', {'user_id': userId, 'tenant_id': tenantId, 'channel': requestedChannel});
                    channel.sink.add(jsonEncode({'type': 'SUBSCRIBE_SUCCESS', 'channel': requestedChannel}));

                    try {
                      final crdt = await _getTenantCrdt(tenantId);

                      // 1. Send Tasks
                      final allTasks = await crdt.query('SELECT * FROM "$tenantId".tasks');
                      for (final record in allTasks) {
                        if (record['is_deleted'] == true || record['is_deleted'] == 1) continue;

                        final cleanData = {
                          'id': record['id'],
                          'name': record['name'],
                          'start_date': record['start_date'],
                          'end_date': record['end_date'],
                          'parent_id': record['parent_id'],
                          'gantt_type': record['gantt_type'], // Send gantt_type
                          'type': record['gantt_type'], // Back-compat
                          'ganttType': record['gantt_type'], // Back-compat
                        };
                        final envelope = {
                          'type': 'UPDATE_TASK',
                          'data': {'data': cleanData, 'gantt_type': record['gantt_type']},
                          'timestamp': DateTime.now().millisecondsSinceEpoch,
                          'actorId': 'server-sync',
                        };
                        channel.sink.add(jsonEncode(envelope));
                      }

                      // 2. Send Dependencies
                      final allDeps = await crdt.query('SELECT * FROM "$tenantId".dependencies');
                      for (final record in allDeps) {
                        if (record['is_deleted'] == true || record['is_deleted'] == 1) continue;

                        final cleanData = {
                          'predecessorTaskId': record['predecessor_task_id'],
                          'successorTaskId': record['successor_task_id'],
                          'type': record['dependency_type'],
                          'dependency_type': record['dependency_type'],
                          'dependencyType': record['dependency_type'],
                        };
                        final envelope = {
                          'type': 'INSERT_DEPENDENCY',
                          'data': {'data': cleanData},
                          'timestamp': DateTime.now().millisecondsSinceEpoch,
                          'actorId': 'server-sync',
                        };
                        channel.sink.add(jsonEncode(envelope));
                      }

                      // 3. Send Resources
                      final allResources = await crdt.query('SELECT * FROM "$tenantId".resources');
                      for (final record in allResources) {
                        if (record['is_deleted'] == true || record['is_deleted'] == 1) continue;

                        final cleanData = {
                          'id': record['id'],
                          'name': record['name'],
                          'parentId': record['parent_id'],
                          'parent_id': record['parent_id'],
                          'isExpanded': record['is_expanded'],
                          'is_expanded': record['is_expanded'],
                          'gantt_type': record['gantt_type'],
                        };
                        final envelope = {
                          'type': 'INSERT_RESOURCE',
                          'data': {'data': cleanData},
                          'timestamp': DateTime.now().millisecondsSinceEpoch,
                          'actorId': 'server-sync',
                        };
                        channel.sink.add(jsonEncode(envelope));
                      }
                    } catch (e) {
                      JsonLogger.error('DB_ERROR', {'error': e.toString(), 'tenant_id': tenantId});
                    }
                  } else {
                    JsonLogger.warn('SECURITY_ALERT', {'message': 'Cross-tenant subscription attempt', 'user_id': userId});
                    channel.sink.add(jsonEncode({'error': 'Forbidden channel'}));
                  }
                },
                operation: (msg) async {
                  final currentChannel = clientInfo.currentChannel;
                  JsonLogger.info('OPERATION_RECEIVED', {
                    'type': msg.type,
                    'user_id': userId,
                    'tenant_id': tenantId,
                    'data_summary': msg.data.toString().substring(0, (msg.data.toString().length < 100 ? msg.data.toString().length : 100)),
                  });

                  if (currentChannel != null) {
                    try {
                      final crdt = await _getTenantCrdt(clientInfo.tenantId);
                      final type = msg.type;

                      if (type == 'INSERT_DEPENDENCY') {
                        var data = msg.data['data'];
                        if (data != null && data['data'] != null && data['data'] is Map) {
                          // Handle double nesting (data.data) which seems to be sent by tests/client
                          data = data['data'];
                        }
                        final pred = data['predecessorTaskId'];
                        final succ = data['successorTaskId'];
                        final depType = data['dependency_type'] ?? data['dependencyType'] ?? data['type'] ?? 'finishToStart';

                        await crdt.execute(
                          'INSERT INTO "${clientInfo.tenantId}".dependencies (predecessor_task_id, successor_task_id, dependency_type) VALUES (?, ?, ?) ON CONFLICT DO NOTHING',
                          [pred, succ, depType],
                        );
                      } else if (type == 'DELETE_DEPENDENCY') {
                        var data = msg.data['data'];
                        if (data != null && data['data'] != null && data['data'] is Map) {
                          data = data['data'];
                        }
                        final pred = data['predecessorTaskId'];
                        final succ = data['successorTaskId'];

                        await crdt.execute('DELETE FROM "${clientInfo.tenantId}".dependencies WHERE predecessor_task_id = ? AND successor_task_id = ?', [
                          pred,
                          succ,
                        ]);
                      } else if (type == 'RESET_DATA') {
                        try {
                          await crdt.execute('DELETE FROM "${clientInfo.tenantId}".dependencies');
                          await crdt.execute('DELETE FROM "${clientInfo.tenantId}".tasks');
                          JsonLogger.info('DATA_RESET', {'tenant_id': clientInfo.tenantId, 'user_id': userId});

                          final tenantChannel = _channels[clientInfo.tenantId];
                          if (tenantChannel != null) {
                            final resetMsg = jsonEncode({
                              'type': 'RESET_DATA',
                              'data': {},
                              'timestamp': DateTime.now().millisecondsSinceEpoch,
                              'actorId': userId,
                            });
                            for (final client in tenantChannel) {
                              if (client != channel) {
                                client.sink.add(resetMsg);
                              }
                            }
                          }
                        } catch (e) {
                          JsonLogger.error('RESET_FAILED', {'error': e.toString(), 'tenant_id': clientInfo.tenantId});
                        }
                      } else if (type == 'UPDATE_TASK' || type == 'INSERT_TASK' || type == 'INSERT_RESOURCE') {
                        final payload = msg.data;
                        if (payload['data'] is Map) {
                          final innerData = Map<String, dynamic>.from(payload['data'] as Map);

                          if (innerData.containsKey('data') && innerData['data'] is Map) {
                            final nestedData = Map<String, dynamic>.from(innerData['data'] as Map);
                            innerData.addAll(nestedData);
                          }

                          if (!innerData.containsKey('gantt_type') && payload.containsKey('gantt_type')) {
                            innerData['gantt_type'] = payload['gantt_type'];
                          }

                          String tableName = 'tasks';
                          if (type == 'INSERT_RESOURCE') tableName = 'resources';
                          final table = '"${clientInfo.tenantId}".$tableName';

                          if (!innerData.containsKey('id')) {
                            JsonLogger.error('MISSING_ID', {'payload': innerData});
                            throw Exception('Missing ID');
                          }

                          final dbData = <String, dynamic>{};
                          final keyMap = {
                            'id': 'id',
                            'name': 'name',
                            'type': 'gantt_type',
                            'ganttType': 'gantt_type',
                            'gantt_type': 'gantt_type',
                            'parentId': 'parent_id',
                            'parentid': 'parent_id',
                            'parent_id': 'parent_id',
                            'startDate': 'start_date',
                            'startdate': 'start_date',
                            'start_date': 'start_date',
                            'endDate': 'end_date',
                            'enddate': 'end_date',
                            'end_date': 'end_date',
                            'isDeleted': 'is_deleted',
                            'isdeleted': 'is_deleted',
                            'is_deleted': 'is_deleted',
                            'nodeId': 'node_id',
                            'nodeid': 'node_id',
                            'node_id': 'node_id',
                            'modified': 'modified',
                            'hlc': 'hlc',
                            'isExpanded': 'is_expanded',
                            'is_expanded': 'is_expanded',
                          };

                          innerData.forEach((k, v) {
                            if (keyMap.containsKey(k)) {
                              dbData[keyMap[k]!] = v;
                            }
                          });

                          if (!dbData.containsKey('id')) {
                            dbData['id'] = innerData['id'];
                          }

                          final columns = dbData.keys.join(', ');
                          final placeholders = List.filled(dbData.length, '?').join(', ');
                          final values = dbData.values.toList();
                          final updates = dbData.keys.map((col) => '$col = EXCLUDED.$col').join(', ');

                          await crdt.execute('INSERT INTO $table ($columns) VALUES ($placeholders) ON CONFLICT (id) DO UPDATE SET $updates', values);
                        }
                      } else if (type == 'DELETE' || type == 'DELETE_TASK' || type == 'DELETE_RESOURCE') {
                        final payload = msg.data;
                        final innerData = payload['data'] as Map;
                        final id = innerData['id'];

                        String tableName = 'tasks';
                        if (type == 'DELETE_RESOURCE') tableName = 'resources';
                        final table = '"${clientInfo.tenantId}".$tableName';

                        if (id != null) {
                          await crdt.execute('UPDATE $table SET is_deleted = TRUE WHERE id = ?', [id]);
                        }
                      } else if (type == 'CURSOR_MOVE') {
                        // Just broadcast, do not persist
                        final subscribers = _channels[currentChannel];
                        if (subscribers != null) {
                          final encoded = jsonEncode(msg.data);
                          for (final client in subscribers) {
                            if (client != channel) {
                              client.sink.add(encoded);
                            }
                          }
                        }
                        // Skip the default broadcast logic at the end of the block to avoid double sending if we handled it here exclusively.
                        // Actually, the block below handles broadcasting for everything EXCEPT RESET_DATA.
                        // To avoid double logic, we can just do nothing here and let the fallthrough handle broadcast?
                        // BUT, we need to ensure we DO NOT enter the DB write try/catch block below or any DB logic.
                        // The current structure has DB logic mixed with broadcast.
                        // Let's refactor slightly:
                        // The DB logic is essentially inside the specific `if` blocks (INSERT, DELETE, etc).
                        // So if we just have an empty block for CURSOR_MOVE, it will skip DB and fall through to broadcast.
                        // However, the broadcast logic is at the end of the loop:
                        /*
                        // Broadcast to others
                        if (type != 'RESET_DATA') {
                           ...
                        }
                        */
                        // So, effectively, handling it here is just about ensuring we don't error out.
                        // Since there is no `else` block that throws (just an UNKNOWN_OPERATION log),
                        // we can just let it fall through to the broadcast logic.
                        // However, to be explicit and avoid "UNKNOWN_OPERATION" log, we should have an empty block.
                      } else if (type == 'GHOST_UPDATE' || type == 'PRESENCE_UPDATE') {
                        // Just broadcast, do not persist.
                        // We rely on the broadcast logic below if it falls through,
                        // BUT we must ensure the `if (type != 'RESET_DATA')` block picks it up.
                        // Actually, looking at the code, falling through this if-else chain
                        // hits the broadcast block.
                        // So we just need an empty block here to avoid 'UNKNOWN_OPERATION'.
                      } else {
                        JsonLogger.info('UNKNOWN_OPERATION', {'type': type, 'data': msg.data});
                      }

                      // Broadcast to others
                      if (type != 'RESET_DATA') {
                        final subscribers = _channels[currentChannel];
                        if (subscribers != null) {
                          final envelope = {
                            'type': msg.type,
                            'data': (msg as dynamic).data,
                            'timestamp': (msg as dynamic).timestamp,
                            'actorId': (msg as dynamic).actorId,
                          };
                          final encoded = jsonEncode(envelope);
                          for (final client in subscribers) {
                            if (client != channel) {
                              client.sink.add(encoded);
                            }
                          }
                        }
                      }
                    } catch (e) {
                      JsonLogger.error('DB_WRITE_ERROR', {'error': e.toString(), 'tenant_id': clientInfo.tenantId});
                    }
                  }
                },
                error: (_) async {},
              );
            } catch (e) {
              JsonLogger.error('MSG_PROCESSING_ERROR', {'error': e.toString()});
            }
          }
        } catch (e) {
          JsonLogger.error('STREAM_ERROR', {'error': e.toString()});
        } finally {
          final currentChannel = clientInfo.currentChannel;
          if (currentChannel != null) _channels[currentChannel]?.remove(channel);
          _clientInfos.remove(channel);
          JsonLogger.info('CLIENT_DISCONNECTED', {'user_id': userId, 'tenant_id': tenantId});
        }
      }();
    });

    return handler(request);
  });

  app.get('/health', (Request request) => Response.ok('OK'));

  // Compose Pipeline
  final handler = const Pipeline()
      .addMiddleware(corsHeaders())
      .addMiddleware(logRequests())
      .addMiddleware(authMiddleware(jwtSecret, authService))
      .addHandler(app.call);

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  JsonLogger.info('SERVER_START', {'host': server.address.host, 'port': server.port});
}
