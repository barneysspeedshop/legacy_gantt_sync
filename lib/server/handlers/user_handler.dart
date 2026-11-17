import 'dart:convert';

import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:legacy_gantt_sync/server/services/client_service.dart';
import 'package:legacy_gantt_sync/server/services/pub_sub_service.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

class UserHandler {
  final AuthService authService;
  final PubSubService pubSubService;
  final ClientService clientService;

  UserHandler(this.authService, this.pubSubService, this.clientService);

  Router get router {
    final router = Router();
    router.post('/users', _createUser);
    router.delete('/users/<userId>', _deleteUser);
    router.post('/users/<userId>/kick', _kickUser);
    router.post('/users/<userId>/undelete', _undeleteUser);
    return router;
  }

  Future<Response> _createUser(Request request) async {
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    String targetTenantId;
    if (body.containsKey('tenantId')) {
      if (creatorRole != 'superuser') {
        return Response.forbidden(
          'Only superusers can create users for other tenants',
        );
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
      return Response.forbidden(
        'Only superusers can create superuser accounts',
      );
    }

    try {
      final user = await authService.registerUser(
        targetTenantId,
        body['username'],
        body['password'],
        role,
      );

      final updateMsg = {
        'type': 'USER_LIST_UPDATE',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': request.context['auth.userId'] ?? 'admin',
      };
      pubSubService.publish(
        'tenant_users_\$targetTenantId',
        jsonEncode(updateMsg),
      );

      pubSubService.publish(
        'admin_updates',
        jsonEncode({
          'type': 'TENANT_LIST_UPDATE',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );

      return Response.ok(
        jsonEncode({'userId': user.id, 'message': 'User created'}),
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> _deleteUser(Request request, String userId) async {
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    if (userId.startsWith('superuser@')) {
      return Response.forbidden('Cannot revoke superuser account');
    }

    try {
      if (creatorRole != 'superuser') {
        final targetUser = await authService.getUser(userId);
        if (targetUser == null) {
          return Response.notFound('User not found');
        }
        if (targetUser.tenantId != creatorTenantId) {
          return Response.forbidden('Cannot manage users of another tenant');
        }
      }

      await authService.revokeUser(userId);

      final kickedCount = await clientService.kickUser(
        userId,
        4003,
        'User revoked',
      );
      JsonLogger.info('USER_KICKED', {
        'userId': userId,
        'connection_count': kickedCount,
      });

      final tenantIdToNotify = creatorRole == 'superuser'
          ? (await authService.getUser(userId))?.tenantId
          : creatorTenantId;
      if (tenantIdToNotify != null) {
        pubSubService.publish(
          'tenant_users_\$tenantIdToNotify',
          jsonEncode({
            'type': 'USER_LIST_UPDATE',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      }
      pubSubService.publish(
        'admin_updates',
        jsonEncode({
          'type': 'TENANT_LIST_UPDATE',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );

      return Response.ok('User revoked');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  }

  Future<Response> _kickUser(Request request, String userId) async {
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    try {
      if (creatorRole != 'superuser') {
        final targetUser = await authService.getUser(userId);
        if (targetUser == null) {
          return Response.notFound('User not found');
        }
        if (targetUser.tenantId != creatorTenantId) {
          return Response.forbidden('Cannot manage users of another tenant');
        }
      }

      final kickedCount = await clientService.kickUser(
        userId,
        4000,
        'Kicked by admin',
      );
      JsonLogger.info('USER_KICKED', {
        'userId': userId,
        'connection_count': kickedCount,
      });

      return Response.ok(
        jsonEncode({'message': 'User kicked', 'count': kickedCount}),
      );
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  }

  Future<Response> _undeleteUser(Request request, String userId) async {
    final creatorTenantId = request.context['auth.tenantId'] as String?;
    final creatorRole = request.context['auth.role'] as String;

    try {
      if (creatorRole != 'superuser') {
        final targetUser = await authService.getUser(userId);
        if (targetUser == null) {
          return Response.notFound('User not found');
        }
        if (targetUser.tenantId != creatorTenantId) {
          return Response.forbidden('Cannot manage users of another tenant');
        }
      }

      await authService.undeleteUser(userId);

      final tenantIdToNotify = creatorRole == 'superuser'
          ? (await authService.getUser(userId))?.tenantId
          : creatorTenantId;
      if (tenantIdToNotify != null) {
        pubSubService.publish(
          'tenant_users_\$tenantIdToNotify',
          jsonEncode({
            'type': 'USER_LIST_UPDATE',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      }
      pubSubService.publish(
        'admin_updates',
        jsonEncode({
          'type': 'TENANT_LIST_UPDATE',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );

      return Response.ok('User restored');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  }
}
