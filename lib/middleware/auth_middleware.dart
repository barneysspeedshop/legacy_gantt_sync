import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';

import '../services/auth_service.dart';
import '../utils/logger.dart';

Middleware authMiddleware(String secret, AuthService authService) {
  return (Handler innerHandler) {
    return (Request request) async {
      // 1. Allow public auth paths
      if (request.url.path.startsWith('auth/')) {
        return innerHandler(request);
      }

      // 2. Allow health check
      if (request.url.path == 'health') {
        return innerHandler(request);
      }

      // 3. Extract Token
      String? token;
      final authHeader = request.headers['Authorization'];
      if (authHeader != null && authHeader.startsWith('Bearer ')) {
        token = authHeader.substring(7);
      }

      // Also check query param for WebSocket connections
      token ??= request.url.queryParameters['token'];

      if (token == null) {
        // Allow WebSocket handshake to proceed without token (will authenticate in-band)
        if (request.url.path == 'ws') {
          return innerHandler(request);
        }
        return Response.forbidden('Missing authentication token');
      }

      try {
        final jwt = JWT.verify(token, SecretKey(secret));
        // Payload contains: sub (userId), tenant_id, role

        final payload = jwt.payload;
        final userId = payload['sub'] as String;
        final tenantId = payload['tenant_id'] as String?;

        // Strict DB Check
        if (!await authService.isUserActive(userId)) {
          return Response.forbidden('User deactivated');
        }

        if (tenantId != null && !await authService.isTenantActive(tenantId)) {
          return Response.forbidden('Tenant deactivated');
        }

        // Pass payload downstream via context
        final updatedRequest = request.change(context: {'auth.userId': userId, 'auth.tenantId': tenantId, 'auth.role': payload['role']});

        return innerHandler(updatedRequest);
      } on JWTExpiredException {
        return Response.forbidden('Token expired');
      } on JWTException catch (e) {
        JsonLogger.warn('AUTH_INVALID_TOKEN', {'error': e.toString()});
        return Response.forbidden('Invalid token');
      } catch (e) {
        JsonLogger.error('AUTH_ERROR', {'error': e.toString()});
        return Response.internalServerError(body: 'Auth validation error');
      }
    };
  };
}

Middleware roleMiddleware(List<String> allowedRoles) {
  return (Handler innerHandler) {
    return (Request request) {
      final userRole = request.context['auth.role'] as String?;
      if (userRole == null || !allowedRoles.contains(userRole)) {
        return Response.forbidden('Insufficient permissions');
      }
      return innerHandler(request);
    };
  };
}
