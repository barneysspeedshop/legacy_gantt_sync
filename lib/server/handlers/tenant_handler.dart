import 'dart:convert';

import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:legacy_gantt_sync/server/services/client_service.dart';
import 'package:legacy_gantt_sync/server/services/pub_sub_service.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

class TenantHandler {
  final AuthService authService;
  final PubSubService pubSubService;
  final ClientService clientService;

  TenantHandler(this.authService, this.pubSubService, this.clientService);

  Router get router {
    final router = Router();
    router.post('/admin/tenants', _createTenant);
    router.get('/admin/tenants', _listTenants);
    router.get('/admin/tenants/<tenantId>/users', _listTenantUsers);
    router.delete('/admin/tenants/<tenantId>', _deleteTenant);
    router.post('/admin/tenants/<tenantId>/undelete', _undeleteTenant);
    return router;
  }

  Future<Response> _createTenant(Request request) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final tenant = await authService.registerTenant(
        body['tenantName'],
        body['adminUsername'],
        body['adminPassword'],
      );

      final updateMsg = {
        'type': 'TENANT_LIST_UPDATE',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': request.context['auth.userId'] ?? 'admin',
      };
      pubSubService.publish('admin_updates', jsonEncode(updateMsg));

      return Response.ok(
        jsonEncode({
          'tenantId': tenant.id,
          'message': 'Tenant registered successfully',
        }),
      );
    } catch (e) {
      JsonLogger.error('REGISTER_ERROR', {'error': e.toString()});
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  Future<Response> _listTenants(Request request) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      final tenants = await authService.getAllTenants();
      final tenantsWithStats = await Future.wait(
        tenants.map((t) async {
          final activeConnections = clientService.getActiveConnectionsCount(
            t.id,
          );
          final userCount = await authService.getUserCount(t.id);
          return {
            'id': t.id,
            'name': t.name,
            'isActive': t.isActive,
            'activeConnections': activeConnections,
            'userCount': userCount,
          };
        }),
      );
      return Response.ok(jsonEncode(tenantsWithStats));
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  }

  Future<Response> _listTenantUsers(Request request, String tenantId) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      final users = await authService.getUsersByTenant(tenantId);
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
                  'isConnected': clientService.isUserConnected(u.id),
                },
              )
              .toList(),
        ),
      );
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  }

  Future<Response> _deleteTenant(Request request, String tenantId) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    if (tenantId == 'system') {
      return Response.forbidden('Cannot delete system tenant');
    }

    try {
      await authService.revokeTenant(tenantId);

      final kickedCount = await clientService.kickTenant(
        tenantId,
        4003,
        'Tenant revoked',
      );
      JsonLogger.info('TENANT_REVOKED', {
        'tenantId': tenantId,
        'kicked_users': kickedCount,
      });

      pubSubService.publish(
        'admin_updates',
        jsonEncode({
          'type': 'TENANT_LIST_UPDATE',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );

      return Response.ok('Tenant revoked');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  }

  Future<Response> _undeleteTenant(Request request, String tenantId) async {
    final role = request.context['auth.role'] as String;
    if (role != 'superuser') {
      return Response.forbidden('Requires superuser role');
    }

    try {
      await authService.undeleteTenant(tenantId);
      pubSubService.publish(
        'admin_updates',
        jsonEncode({
          'type': 'TENANT_LIST_UPDATE',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      return Response.ok('Tenant restored');
    } catch (e) {
      return Response.internalServerError(body: e.toString());
    }
  }
}
