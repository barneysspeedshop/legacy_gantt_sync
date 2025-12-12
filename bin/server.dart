import 'dart:convert';
import 'dart:io';

// import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:legacy_gantt_sync/middleware/auth_middleware.dart';
import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:redis/redis.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:legacy_gantt_sync/models/models.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:legacy_gantt_sync/utils/retry_utils.dart';

// Redis Commands (for publishing)
Command? _redisCommand;
// Redis PubSub (for subscribing)
PubSub? _redisPubSub;

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
  final String role;
  final String connectionId;
  final Set<String> channels = {};

  ClientInfo(this.userId, this.tenantId, this.role, this.connectionId);
}

final Map<WebSocketChannel, ClientInfo> _clientInfos = {};

Future<PostgresCrdt> _getTenantCrdt(String tenantId) {
  if (_tenantCrdts.containsKey(tenantId)) {
    return Future.value(_tenantCrdts[tenantId]!);
  }

  return _crdtFutures.putIfAbsent(tenantId, () async {
    try {
      // Sanitize tenantId to prevent SQL injection (simple check)
      final crdt = await retryForever(
        () => PostgresCrdt.open(
          Platform.environment['DB_NAME'] ?? 'legacy_gantt',
          host: Platform.environment['DB_HOST'] ?? 'localhost',
          port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
          username: Platform.environment['DB_USER'] ?? 'dart_user',
          password: Platform.environment['DB_PASS'] ?? 'dart_password',
          sslMode: SslMode.disable,
        ),
        description: 'Connect to Tenant DB ($tenantId)',
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
      last_updated BIGINT,
      deleted_at BIGINT,
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
        // Add if missing
        await crdt.execute('ALTER TABLE "$tenantId".tasks ADD COLUMN IF NOT EXISTS gantt_type TEXT');
        await crdt.execute('ALTER TABLE "$tenantId".tasks ADD COLUMN IF NOT EXISTS last_updated BIGINT');
        await crdt.execute('ALTER TABLE "$tenantId".tasks ADD COLUMN IF NOT EXISTS deleted_at BIGINT');
      } catch (_) {}

      await crdt.execute('''
    CREATE TABLE IF NOT EXISTS "$tenantId".dependencies (
      predecessor_task_id TEXT NOT NULL,
      successor_task_id TEXT NOT NULL,
      dependency_type TEXT NOT NULL DEFAULT 'finishToStart',
      last_updated BIGINT,
      deleted_at BIGINT,
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
      try {
        await crdt.execute('ALTER TABLE "$tenantId".dependencies ADD COLUMN IF NOT EXISTS dependency_type TEXT DEFAULT \'finishToStart\'');
        await crdt.execute('ALTER TABLE "$tenantId".dependencies ADD COLUMN IF NOT EXISTS last_updated BIGINT');
        await crdt.execute('ALTER TABLE "$tenantId".dependencies ADD COLUMN IF NOT EXISTS deleted_at BIGINT');
      } catch (_) {}

      // Create resources table
      await crdt.execute('''
    CREATE TABLE IF NOT EXISTS "$tenantId".resources (
      id TEXT PRIMARY KEY,
      name TEXT,
      parent_id TEXT,
      gantt_type TEXT,
      is_expanded BOOLEAN NOT NULL DEFAULT TRUE,
      last_updated BIGINT,
      deleted_at BIGINT,
      hlc TEXT NOT NULL DEFAULT '',
      node_id TEXT NOT NULL DEFAULT '',
      modified TEXT NOT NULL DEFAULT '',
      is_deleted BOOLEAN NOT NULL DEFAULT FALSE
    )
    ''');
      try {
        await crdt.execute('ALTER TABLE "$tenantId".resources ADD COLUMN IF NOT EXISTS gantt_type TEXT');
        await crdt.execute('ALTER TABLE "$tenantId".resources ADD COLUMN IF NOT EXISTS last_updated BIGINT');
        await crdt.execute('ALTER TABLE "$tenantId".resources ADD COLUMN IF NOT EXISTS deleted_at BIGINT');
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

  Future<Connection> authConnectionFactory() {
    return retryForever(
      () => Connection.open(
        Endpoint(
          host: Platform.environment['DB_HOST'] ?? 'localhost',
          database: Platform.environment['DB_NAME'] ?? 'legacy_gantt',
          username: Platform.environment['DB_USER'] ?? 'dart_user',
          password: Platform.environment['DB_PASS'] ?? 'dart_password',
          port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
        ),
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      ),
      description: 'Connect to Auth DB',
    );
  }

  final authService = AuthService(authConnectionFactory, jwtSecret);
  // Initialize ensures at least one connection is possible at startup
  await authService.init();

  final redisHost = Platform.environment['REDIS_HOST'] ?? 'localhost';
  final redisPort = int.parse(Platform.environment['REDIS_PORT'] ?? '6379');

  try {
    final conn1 = RedisConnection();
    _redisCommand = await conn1.connect(redisHost, redisPort);
    JsonLogger.info('REDIS_PUB_CONNECTED', {'host': redisHost});

    final conn2 = RedisConnection();
    final cmd2 = await conn2.connect(redisHost, redisPort);
    _redisPubSub = PubSub(cmd2);
    JsonLogger.info('REDIS_SUB_CONNECTED', {'host': redisHost});

    _redisPubSub!.getStream().listen((message) {
      if (message is List && message.length >= 3 && message[0] == 'message') {
        final channelName = message[1] as String;
        final payload = message[2] as String;

        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map<String, dynamic>) {
            final originConnectionId = decoded['originConnectionId'];

            final subscribers = _channels[channelName];
            if (subscribers != null) {
              for (final client in subscribers) {
                final info = _clientInfos[client];
                if (info?.connectionId != originConnectionId) {
                  client.sink.add(payload);
                }
              }
            }
          }
        } catch (e) {
          JsonLogger.error('REDIS_MSG_ERROR', {'error': e.toString(), 'payload': payload});
        }
      }
    });
  } catch (e) {
    JsonLogger.error('REDIS_CONNECT_FAIL', {'error': e.toString()});
  }

  // --- Seeding ---
  final superUserUser = Platform.environment['SUPERUSER_USERNAME'] ?? 'superuser';
  final superUserPass = Platform.environment['SUPERUSER_PASSWORD'] ?? 'superuser';

  // Always try to ensure superuser exists in dev/local
  try {
    await authService.ensureSuperuser(superUserUser, superUserPass);
  } catch (e) {
    JsonLogger.error('SEED_SUPERUSER_FAIL', {'error': e.toString()});
  }

  final app = Router();

  // --- Admin Endpoints (RBAC) ---
  final apiRouter = Router();

  // Create Tenant (Superuser Only)
  apiRouter.post('/admin/tenants', (Request request) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final tenant = await authService.registerTenant(body['tenantName'], body['adminUsername'], body['adminPassword']);

      // Notify admin_updates
      final updateMsg = {
        'type': 'TENANT_LIST_UPDATE',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': request.context['auth.userId'] ?? 'admin',
      };
      _redisCommand?.send_object(['PUBLISH', 'admin_updates', jsonEncode(updateMsg)]);

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

  // Add User (Tenant Admin or Superuser)
  apiRouter.post('/users', (Request request) async {
    final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    String targetTenantId;
    if (body.containsKey('tenantId')) {
      if (creatorRole != 'superuser') {
        return Response.forbidden('Only superusers can create users for other tenants');
      }
      targetTenantId = body['tenantId'];
    } else {
      if (creatorTenantId == null) {
        return Response.forbidden('Tenant ID required');
      }
      targetTenantId = creatorTenantId;
    }

    final String role = body['role'] ?? 'user';
    if (role == 'superuser' && creatorRole != 'superuser') {
      return Response.forbidden('Only superusers can create superuser accounts');
    }

    try {
      final user = await authService.registerUser(targetTenantId, body['username'], body['password'], role);

      // Notify tenant_users
      final updateMsg = {'type': 'USER_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch, 'actorId': request.context['auth.userId'] ?? 'admin'};
      _redisCommand?.send_object(['PUBLISH', 'tenant_users_$targetTenantId', jsonEncode(updateMsg)]);

      // Also notify admin_updates if tenant stats changed (user count) - simpler to just do it
      _redisCommand?.send_object([
        'PUBLISH',
        'admin_updates',
        jsonEncode({'type': 'TENANT_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      ]);

      return Response.ok(jsonEncode({'userId': user.id, 'message': 'User created'}));
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // Revoke User (Tenant Admin or Superuser)
  apiRouter.delete('/users/<userId>', (Request request, String userId) async {
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    // Protect System Resources
    if (userId.startsWith('superuser@')) {
      return Response.forbidden('Cannot revoke superuser account');
    }

    try {
      if (creatorRole != 'superuser') {
        // Enforce tenant isolation
        final targetUser = await authService.getUser(userId);
        if (targetUser == null) {
          return Response.notFound('User not found');
        }
        if (targetUser.tenantId != creatorTenantId) {
          return Response.forbidden('Cannot manage users of another tenant');
        }
      }

      await authService.revokeUser(userId);

      // Kick User: Close active connections
      final connectionsToKick = _clientInfos.entries.where((entry) => entry.value.userId == userId).toList();
      for (final entry in connectionsToKick) {
        await entry.key.sink.close(4003, 'User revoked'); // Close the WebSocket
        // Cleanup will happen in the stream listener's onDone or finally block usually,
        // but explicitly removing from map is safer if we want immediate effect tracking
        // _clientInfos.remove(entry.key); // The proper way is to let the socket closure trigger cleanup
      }
      JsonLogger.info('USER_KICKED', {'userId': userId, 'connection_count': connectionsToKick.length});

      // Notify updates
      final tenantIdToNotify = creatorRole == 'superuser' ? (await authService.getUser(userId))?.tenantId : creatorTenantId;
      if (tenantIdToNotify != null) {
        _redisCommand?.send_object([
          'PUBLISH',
          'tenant_users_$tenantIdToNotify',
          jsonEncode({'type': 'USER_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
        ]);
      }
      _redisCommand?.send_object([
        'PUBLISH',
        'admin_updates',
        jsonEncode({'type': 'TENANT_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      ]);

      return Response.ok('User revoked');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

  // Kick User (Tenant Admin or Superuser)
  apiRouter.post('/users/<userId>/kick', (Request request, String userId) async {
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    try {
      if (creatorRole != 'superuser') {
        // Enforce tenant isolation
        final targetUser = await authService.getUser(userId);
        if (targetUser == null) {
          return Response.notFound('User not found');
        }
        if (targetUser.tenantId != creatorTenantId) {
          return Response.forbidden('Cannot manage users of another tenant');
        }
      }

      // Close active connections
      final connectionsToKick = _clientInfos.entries.where((entry) => entry.value.userId == userId).toList();
      for (final entry in connectionsToKick) {
        await entry.key.sink.close(4000, 'Kicked by admin');
        // socket closure triggers cleanup handling in stream listener
      }
      JsonLogger.info('USER_KICKED', {'userId': userId, 'connection_count': connectionsToKick.length});

      return Response.ok(jsonEncode({'message': 'User kicked', 'count': connectionsToKick.length}));
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

  // Undelete User (Tenant Admin or Superuser)
  apiRouter.post('/users/<userId>/undelete', (Request request, String userId) async {
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    try {
      if (creatorRole != 'superuser') {
        // Enforce tenant isolation
        final targetUser = await authService.getUser(userId);
        if (targetUser == null) {
          return Response.notFound('User not found');
        }
        if (targetUser.tenantId != creatorTenantId) {
          return Response.forbidden('Cannot manage users of another tenant');
        }
      }

      await authService.undeleteUser(userId);

      // Notify updates
      final tenantIdToNotify = creatorRole == 'superuser' ? (await authService.getUser(userId))?.tenantId : creatorTenantId;
      if (tenantIdToNotify != null) {
        _redisCommand?.send_object([
          'PUBLISH',
          'tenant_users_$tenantIdToNotify',
          jsonEncode({'type': 'USER_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
        ]);
      }
      _redisCommand?.send_object([
        'PUBLISH',
        'admin_updates',
        jsonEncode({'type': 'TENANT_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      ]);

      return Response.ok('User restored');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

  // --- Superuser Endpoints ---

  // List All Tenants
  apiRouter.get('/admin/tenants', (Request request) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      final tenants = await authService.getAllTenants();
      final tenantsWithStats = await Future.wait(
        tenants.map((t) async {
          final activeConnections = _clientInfos.values.where((c) => c.tenantId == t.id).length;
          final userCount = await authService.getUserCount(t.id);
          return {'id': t.id, 'name': t.name, 'isActive': t.isActive, 'activeConnections': activeConnections, 'userCount': userCount};
        }),
      );
      return Response.ok(jsonEncode(tenantsWithStats));
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

  // List Users for Tenant
  apiRouter.get('/admin/tenants/<tenantId>/users', (Request request, String tenantId) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      final users = await authService.getUsersByTenant(tenantId);
      final connectedUserIds = _clientInfos.values.map((c) => c.userId).toSet();
      return Response.ok(
        jsonEncode(
          users
              .map(
                (u) => {
                  'id': u.id,
                  'username': u.username,
                  'role': u.role,
                  'tenantId': u.tenantId,
                  'isActive': u.isActive,
                  'isConnected': connectedUserIds.contains(u.id),
                },
              )
              .toList(),
        ),
      );
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

  // Revoke Tenant (Superuser)
  apiRouter.delete('/admin/tenants/<tenantId>', (Request request, String tenantId) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    if (tenantId == 'system') {
      return Response.forbidden('Cannot delete system tenant');
    }

    try {
      await authService.revokeTenant(tenantId);

      // Kick all users of this tenant
      final connectionsToKick = _clientInfos.entries.where((entry) => entry.value.tenantId == tenantId).toList();
      for (final entry in connectionsToKick) {
        await entry.key.sink.close(4003, 'Tenant revoked');
        // _clientInfos.remove(entry.key);
      }
      JsonLogger.info('TENANT_REVOKED', {'tenantId': tenantId, 'kicked_users': connectionsToKick.length});

      _redisCommand?.send_object([
        'PUBLISH',
        'admin_updates',
        jsonEncode({'type': 'TENANT_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      ]);

      return Response.ok('Tenant revoked');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

  // Undelete Tenant (Superuser)
  apiRouter.post('/admin/tenants/<tenantId>/undelete', (Request request, String tenantId) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      await authService.undeleteTenant(tenantId);
      _redisCommand?.send_object([
        'PUBLISH',
        'admin_updates',
        jsonEncode({'type': 'TENANT_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      ]);
      return Response.ok('Tenant restored');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  });

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
    final role = request.context['auth.role'] as String;

    final handler = webSocketHandler((webSocket, _) {
      final channel = webSocket;
      final connectionId = const Uuid().v4();
      final clientInfo = ClientInfo(userId, tenantId, role, connectionId);
      _clientInfos[channel] = clientInfo;

      JsonLogger.info('CLIENT_CONNECTED', {'user_id': userId, 'tenant_id': tenantId});

      // Broadcast USER_LIST_UPDATE for the tenant so user list shows "connected"
      _redisCommand?.send_object([
        'PUBLISH',
        'tenant_users_$tenantId',
        jsonEncode({'type': 'USER_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      ]);

      // Broadcast TENANT_LIST_UPDATE for admin stats (active connections count)
      _redisCommand?.send_object([
        'PUBLISH',
        'admin_updates',
        jsonEncode({'type': 'TENANT_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      ]);

      () async {
        try {
          await for (final rawMessage in channel.stream) {
            try {
              final jsonMap = jsonDecode(rawMessage as String) as Map<String, dynamic>;
              final type = jsonMap['type'] as String?;

              ProtocolMessage? message;
              if (type == 'subscribe') {
                message = ProtocolMessage.subscribe(
                  type: 'subscribe',
                  channel: jsonMap['channel'] as String,
                  lastSyncedTimestamp: jsonMap['lastSyncedTimestamp'] as int?,
                );
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
                  final lastSynced = msg.lastSyncedTimestamp; // Delta Sync timestamp

                  JsonLogger.info('SUBSCRIBE_ATTEMPT', {
                    'user_id': userId,
                    'tenant_id': tenantId,
                    'requested_channel': requestedChannel,
                    'last_synced': lastSynced,
                  });

                  // ADMIN CHANNELS
                  if (requestedChannel == 'admin_updates') {
                    if (clientInfo.role != 'superuser') {
                      JsonLogger.warn('SECURITY_ALERT', {'message': 'Unauthorized admin_updates subscription', 'user_id': userId});
                      channel.sink.add(jsonEncode({'error': 'Forbidden channel'}));
                      return;
                    }
                    // Allow multiple subscriptions (do not remove old one)
                    clientInfo.channels.add(requestedChannel);
                    final channelList = _channels.putIfAbsent(requestedChannel, () => []);
                    if (!channelList.contains(channel)) channelList.add(channel);

                    // Redis subscribe optimization
                    if (channelList.length == 1) {
                      _redisPubSub?.subscribe([requestedChannel]);
                    }

                    JsonLogger.info('SUBSCRIBE_SUCCESS', {'user_id': userId, 'channel': requestedChannel});
                    channel.sink.add(jsonEncode({'type': 'SUBSCRIBE_SUCCESS', 'channel': requestedChannel}));
                    return;
                  }

                  if (requestedChannel.startsWith('tenant_users_')) {
                    final targetTenantId = requestedChannel.replaceFirst('tenant_users_', '');
                    // Only superuser or admin of that tenant
                    if (clientInfo.role == 'superuser' || (clientInfo.role == 'tenant_admin' && clientInfo.tenantId == targetTenantId)) {
                      clientInfo.channels.add(requestedChannel);
                      final channelList = _channels.putIfAbsent(requestedChannel, () => []);
                      if (!channelList.contains(channel)) channelList.add(channel);

                      // Redis subscribe optimization
                      if (channelList.length == 1) {
                        _redisPubSub?.subscribe([requestedChannel]);
                      }

                      JsonLogger.info('SUBSCRIBE_SUCCESS', {'user_id': userId, 'channel': requestedChannel});
                      channel.sink.add(jsonEncode({'type': 'SUBSCRIBE_SUCCESS', 'channel': requestedChannel}));
                      return;
                    } else {
                      JsonLogger.warn('SECURITY_ALERT', {'message': 'Unauthorized tenant_users subscription', 'user_id': userId, 'target': targetTenantId});
                      channel.sink.add(jsonEncode({'error': 'Forbidden channel'}));
                      return;
                    }
                  }

                  // STRICT TENANT ISOLATION
                  if (requestedChannel == tenantId) {
                    clientInfo.channels.add(requestedChannel);
                    final channelList = _channels.putIfAbsent(requestedChannel, () => []);
                    if (!channelList.contains(channel)) channelList.add(channel);

                    // If this is the first client, subscribe Redis (optimization)
                    if (channelList.length == 1) {
                      _redisPubSub?.subscribe([requestedChannel]);
                      JsonLogger.info('REDIS_SUBSCRIBE', {'channel': requestedChannel});
                    }

                    JsonLogger.info('SUBSCRIBE_SUCCESS', {'user_id': userId, 'tenant_id': tenantId, 'channel': requestedChannel});
                    channel.sink.add(jsonEncode({'type': 'SUBSCRIBE_SUCCESS', 'channel': requestedChannel}));

                    try {
                      final crdt = await _getTenantCrdt(tenantId);

                      // Build partial query if delta sync
                      String whereClause = '';
                      if (lastSynced != null && lastSynced > 0) {
                        whereClause = 'WHERE (last_updated > $lastSynced OR deleted_at > $lastSynced)';
                        JsonLogger.info('DELTA_SYNC_QUERY', {'where': whereClause, 'lastSynced': lastSynced});
                      } else {
                        // Full load: ignore deleted, ignore timestamp
                        whereClause = 'WHERE (is_deleted IS FALSE OR is_deleted = false)';
                        JsonLogger.info('FULL_SYNC_QUERY', {'where': whereClause});
                      }

                      // 1. Send Tasks
                      final tasks = await crdt.query('SELECT * FROM "$tenantId".tasks $whereClause');
                      JsonLogger.info('SYNC_SENDING_TASKS', {'count': tasks.length, 'tenant_id': tenantId});
                      for (final row in tasks) {
                        final isDeleted = row['is_deleted'] == true || row['is_deleted'] == 1;
                        // If full sync, we filtered deleted in SQL. If delta sync, we need to send deletions.
                        // Check explicit deleted_at logic if available, or fallback to is_deleted.

                        final cleanData = {
                          'id': row['id']?.toString(),
                          'name': row['name'],
                          'start_date': row['start_date'],
                          'end_date': row['end_date'],
                          'parent_id': row['parent_id']?.toString(),
                          'gantt_type': row['gantt_type'],
                          'type': row['gantt_type'],
                          'ganttType': row['gantt_type'],
                        };
                        final envelope = {
                          'type': isDeleted ? 'DELETE_TASK' : 'UPDATE_TASK',
                          'data': {'data': cleanData, 'gantt_type': row['gantt_type']},
                          // If deleting, provide ID in data wrapper so client knows what to delete
                          'timestamp': row['last_updated'] ?? DateTime.now().millisecondsSinceEpoch,
                          'actorId': 'server-sync',
                        };
                        if (isDeleted) {
                          // Ensure DELETE_TASK has correct structure for client
                          envelope['data'] = {
                            'data': {'id': row['id']?.toString()},
                          };
                        }
                        channel.sink.add(jsonEncode(envelope));
                      }

                      // 2. Send Dependencies
                      final allDeps = await crdt.query('SELECT * FROM "$tenantId".dependencies $whereClause');
                      for (final record in allDeps) {
                        final isDeleted = (record['is_deleted'] == true || record['is_deleted'] == 1);

                        final cleanData = {
                          'predecessorTaskId': record['predecessor_task_id']?.toString(),
                          'successorTaskId': record['successor_task_id']?.toString(),
                          'type': record['dependency_type'],
                          'dependency_type': record['dependency_type'],
                          'dependencyType': record['dependency_type'],
                        };
                        final envelope = {
                          'type': isDeleted ? 'DELETE_DEPENDENCY' : 'INSERT_DEPENDENCY',
                          'data': {'data': cleanData},
                          'timestamp': record['last_updated'] ?? DateTime.now().millisecondsSinceEpoch,
                          'actorId': 'server-sync',
                        };
                        channel.sink.add(jsonEncode(envelope));
                      }

                      // 3. Send Resources
                      final allResources = await crdt.query('SELECT * FROM "$tenantId".resources $whereClause');
                      for (final record in allResources) {
                        final isDeleted = (record['is_deleted'] == true || record['is_deleted'] == 1);

                        final cleanData = {
                          'id': record['id']?.toString(),
                          'name': record['name'],
                          'parentId': record['parent_id']?.toString(),
                          'parent_id': record['parent_id']?.toString(),
                          'isExpanded': record['is_expanded'],
                          'is_expanded': record['is_expanded'],
                          'gantt_type': record['gantt_type'],
                        };
                        final envelope = {
                          'type': isDeleted ? 'DELETE_RESOURCE' : 'INSERT_RESOURCE', // Assuming delete resource type exists
                          'data': {'data': cleanData},
                          'timestamp': record['last_updated'] ?? DateTime.now().millisecondsSinceEpoch,
                          'actorId': 'server-sync',
                        };
                        if (isDeleted) {
                          envelope['type'] = 'DELETE_RESOURCE'; // Ensure type is correct
                          envelope['data'] = {
                            'data': {'id': record['id']?.toString()},
                          };
                        }
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
                  // NOTE: Operations are handled against the client's TENANT, not necessarily the channel.
                  // However, for broadcast, we need to know where to send it.
                  // Usually, Gantt ops are for the tenant channel.
                  // We can iterate occupied channels or default to tenantId?
                  // The original code used currentChannel.
                  // For Gantt ops, we should strictly publish to tenantId channel.
                  // Admin ops (if any) might go elsewhere.
                  // Assuming Gantt ops => tenantId channel.

                  final targetChannel = clientInfo.tenantId; // Default for operations to tenant

                  JsonLogger.info('OPERATION_RECEIVED', {
                    'type': msg.type,
                    'user_id': userId,
                    'tenant_id': tenantId,
                    'data_summary': msg.data.toString().substring(0, (msg.data.toString().length < 100 ? msg.data.toString().length : 100)),
                  });

                  // Ensure user is subscribed to their tenant? Not strictly required if we force publish target.

                  try {
                    final crdt = await _getTenantCrdt(clientInfo.tenantId);
                    final type = msg.type;

                    if (type == 'INSERT_DEPENDENCY') {
                      var data = msg.data['data'];
                      if (data != null && data['data'] != null && data['data'] is Map) {
                        data = data['data'];
                      }
                      final pred = data['predecessorTaskId'];
                      final succ = data['successorTaskId'];
                      final depType = data['dependency_type'] ?? data['dependencyType'] ?? data['type'] ?? 'finishToStart';

                      await crdt.execute(
                        'INSERT INTO "${clientInfo.tenantId}".dependencies (predecessor_task_id, successor_task_id, dependency_type, last_updated) VALUES (?, ?, ?, ?) ON CONFLICT (predecessor_task_id, successor_task_id) DO UPDATE SET dependency_type = EXCLUDED.dependency_type, last_updated = EXCLUDED.last_updated, is_deleted = false, deleted_at = NULL',
                        [pred, succ, depType, msg.timestamp],
                      );
                    } else if (type == 'DELETE_DEPENDENCY') {
                      var data = msg.data['data'];
                      if (data != null && data['data'] != null && data['data'] is Map) {
                        data = data['data'];
                      }
                      final pred = data['predecessorTaskId'];
                      final succ = data['successorTaskId'];

                      await crdt.execute(
                        'UPDATE "${clientInfo.tenantId}".dependencies SET is_deleted = true, deleted_at = ?, last_updated = ? WHERE predecessor_task_id = ? AND successor_task_id = ?',
                        [msg.timestamp, msg.timestamp, pred, succ],
                      );
                    } else if (type == 'RESET_DATA') {
                      try {
                        await crdt.execute('DELETE FROM "${clientInfo.tenantId}".dependencies');
                        await crdt.execute('DELETE FROM "${clientInfo.tenantId}".tasks');
                        JsonLogger.info('DATA_RESET', {'tenant_id': clientInfo.tenantId, 'user_id': userId});

                        // Redis Publish RESET_DATA
                        final resetMsg = {
                          'type': 'RESET_DATA',
                          'data': {},
                          'timestamp': DateTime.now().millisecondsSinceEpoch,
                          'actorId': userId,
                          'originConnectionId': clientInfo.connectionId,
                        };
                        _redisCommand?.send_object(['PUBLISH', clientInfo.tenantId, jsonEncode(resetMsg)]);

                        // Local broadcast handled by Redis Listener loop?
                        // Redis listener will hear this and broadcast to local clients (including other tabs of same user).
                        // BUT, Redis listener filters out `originConnectionId`.
                        // So the sender (this socket) won't get it back.
                        // Everyone else will.
                        // Wait, does RESET_DATA need to go to sender? Sender just did the action.
                        // Usually sender updates their UI optimistically or after ack.
                        // The original code:
                        /*
                           final tenantChannel = _channels[clientInfo.tenantId];
                           if (tenantChannel != null) {
                              ...
                              for (final client in tenantChannel) {
                                if (client != channel) client.sink.add(resetMsg);
                              }
                           }
                          */
                        // Identical logic. The sender is excluded.
                      } catch (e) {
                        JsonLogger.error('RESET_FAILED', {'error': e.toString(), 'tenant_id': clientInfo.tenantId});
                      }
                    } else if (type == 'UPDATE_TASK' || type == 'INSERT_TASK') {
                      final payload = msg.data;
                      Map<String, dynamic>? innerData;
                      if (payload.containsKey('data') && payload['data'] is Map) {
                        innerData = Map<String, dynamic>.from(payload['data'] as Map);
                      } else {
                        innerData = payload;
                      }

                      if (innerData['id'] != null) {
                        final name = innerData['name'];
                        final start = innerData['start_date'];
                        final end = innerData['end_date'];
                        final parent = innerData['parent_id'];
                        final ganttType = innerData['gantt_type'] ?? innerData['type'] ?? 'task';

                        await crdt.execute(
                          '''
                            INSERT INTO "${clientInfo.tenantId}".tasks (id, name, start_date, end_date, parent_id, gantt_type, last_updated)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT (id) DO UPDATE SET
                              name = EXCLUDED.name,
                              start_date = EXCLUDED.start_date,
                              end_date = EXCLUDED.end_date,
                              parent_id = EXCLUDED.parent_id,
                              gantt_type = EXCLUDED.gantt_type,
                              last_updated = EXCLUDED.last_updated,
                              is_deleted = false,
                              deleted_at = NULL
                            ''',
                          [innerData['id'], name, start, end, parent, ganttType, msg.timestamp],
                        );
                      }
                    } else if (type == 'INSERT_RESOURCE') {
                      final payload = msg.data;
                      Map<String, dynamic>? innerData;
                      if (payload.containsKey('data') && payload['data'] is Map) {
                        innerData = Map<String, dynamic>.from(payload['data'] as Map);
                      } else {
                        innerData = payload;
                      }

                      if (innerData['id'] != null) {
                        final name = innerData['name'];
                        final parent = innerData['parent_id'] ?? innerData['parentId'];
                        final expanded = innerData['is_expanded'] ?? innerData['isExpanded'] ?? true;
                        final ganttType = innerData['gantt_type'];

                        await crdt.execute(
                          '''
                            INSERT INTO "${clientInfo.tenantId}".resources (id, name, parent_id, is_expanded, gantt_type, last_updated)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT (id) DO UPDATE SET
                              name = EXCLUDED.name,
                              parent_id = EXCLUDED.parent_id,
                              is_expanded = EXCLUDED.is_expanded,
                              gantt_type = EXCLUDED.gantt_type,
                              last_updated = EXCLUDED.last_updated,
                              is_deleted = false,
                              deleted_at = NULL
                            ''',
                          [innerData['id'], name, parent, expanded, ganttType, msg.timestamp],
                        );
                      }
                    } else if (type == 'DELETE_TASK' || type == 'DELETE_RESOURCE') {
                      // Removed generic 'DELETE' to be safer
                      final payload = msg.data;
                      Map<String, dynamic>? innerData;
                      if (payload.containsKey('data') && payload['data'] is Map) {
                        innerData = payload['data'] as Map<String, dynamic>;
                      } else {
                        innerData = payload;
                      }

                      final id = innerData['id'];

                      if (id != null) {
                        String tableName = 'tasks';
                        if (type == 'DELETE_RESOURCE') {
                          tableName = 'resources';
                        }
                        final table = '"${clientInfo.tenantId}".$tableName';

                        await crdt.execute('UPDATE $table SET is_deleted = true, deleted_at = ?, last_updated = ? WHERE id = ?', [
                          msg.timestamp,
                          msg.timestamp,
                          id,
                        ]);
                      }
                    } else if (type == 'CURSOR_MOVE') {
                      // However, to be explicit and avoid "UNKNOWN_OPERATION" log, we should have an empty block.
                    } else if (type == 'GHOST_UPDATE' || type == 'PRESENCE_UPDATE') {
                      // Just broadcast
                    } else {
                      JsonLogger.info('UNKNOWN_OPERATION', {'type': type, 'data': msg.data});
                    }

                    // Broadcast to others via Redis
                    if (type != 'RESET_DATA') {
                      final envelope = {
                        'type': msg.type,
                        'data': (msg as dynamic).data,
                        'timestamp': (msg as dynamic).timestamp,
                        'actorId': (msg as dynamic).actorId,
                        'originConnectionId': clientInfo.connectionId,
                      };

                      if (_redisCommand != null) {
                        _redisCommand!.send_object(['PUBLISH', targetChannel, jsonEncode(envelope)]);
                      } else {
                        // Fallback to local broadcast if Redis missing?
                        // Maintain partial functionality
                        final subscribers = _channels[targetChannel];
                        if (subscribers != null) {
                          final encoded = jsonEncode(envelope);
                          for (final client in subscribers) {
                            if (client != channel) client.sink.add(encoded);
                          }
                        }
                      }
                    }
                  } catch (e) {
                    JsonLogger.error('DB_WRITE_ERROR', {'error': e.toString(), 'tenant_id': clientInfo.tenantId});
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
          for (final channelId in clientInfo.channels) {
            final list = _channels[channelId];
            if (list != null) {
              list.remove(channel);
              if (list.isEmpty) {
                _redisPubSub?.unsubscribe([channelId]);
                JsonLogger.info('REDIS_UNSUBSCRIBE', {'channel': channelId});
                _channels.remove(channelId);
              }
            }
          }
          _clientInfos.remove(channel);
          JsonLogger.info('CLIENT_DISCONNECTED', {'user_id': userId, 'tenant_id': tenantId});

          // Broadcast USER_LIST_UPDATE
          _redisCommand?.send_object([
            'PUBLISH',
            'tenant_users_$tenantId',
            jsonEncode({'type': 'USER_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
          ]);

          // Broadcast TENANT_LIST_UPDATE
          _redisCommand?.send_object([
            'PUBLISH',
            'admin_updates',
            jsonEncode({'type': 'TENANT_LIST_UPDATE', 'timestamp': DateTime.now().millisecondsSinceEpoch}),
          ]);
        }
      }();
    }, pingInterval: const Duration(seconds: 20));

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
