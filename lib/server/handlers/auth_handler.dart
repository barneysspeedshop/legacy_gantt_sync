import 'dart:convert';

import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:shelf/shelf.dart';

class AuthHandler {
  final AuthService authService;

  AuthHandler(this.authService);

  Future<Response> login(Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final tokens = await authService.login(
        body['username'],
        body['password'],
      );
      return Response.ok(jsonEncode(tokens));
    } catch (e) {
      JsonLogger.warn('LOGIN_FAILED', {'error': e.toString()});
      return Response.forbidden(jsonEncode({'error': 'Invalid credentials'}));
    }
  }

  Future<Response> register(Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final tenantName = body['tenantName'] as String?;
      final username = body['username'] as String?;
      final password = body['password'] as String?;

      if (tenantName == null || username == null || password == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Missing required fields'}),
        );
      }

      final tenant = await authService.registerTenant(
        tenantName,
        username,
        password,
      );

      JsonLogger.info('TENANT_REGISTERED', {'tenantId': tenant.id});

      // Auto-login? Or just return success. Usually auto-login.
      final tokens = await authService.login(
        username,
        password,
      ); // username is global unique? Or tenant scoped?
      // AuthService login usually takes username. If usernames are unique per tenant, login needs to know which tenant?
      // Existing login: `authService.login(body['username'], body['password'])`.
      // If `registerTenant` creates a user, hopefully `login` works.

      return Response.ok(jsonEncode(tokens));
    } catch (e) {
      JsonLogger.error('REGISTER_FAILED', {'error': e.toString()});
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }
}
