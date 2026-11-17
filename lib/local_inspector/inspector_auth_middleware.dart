import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:legacy_gantt_sync/services/auth_service.dart';
import 'package:shelf/shelf.dart';

Middleware localInspectorAuth({
  required String jwtSecret,
  required String localToken,
  required AuthService authService,
}) {
  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') return innerHandler(request);

      if (request.headers['x-local-inspector-token'] != localToken) {
        return Response.forbidden('Invalid local inspector token');
      }

      final authorization = request.headers['authorization'];
      if (authorization == null || !authorization.startsWith('Bearer ')) {
        return Response.forbidden('Missing authentication token');
      }

      late final Request authenticatedRequest;
      try {
        final token = authorization.substring(7);
        final jwt = JWT.verify(token, SecretKey(jwtSecret));
        final payload = jwt.payload;
        final userId = payload['sub'] as String?;
        final role = payload['role'] as String?;
        final tenantId = payload['tenant_id'] as String?;

        if (userId == null || role != 'superuser') {
          return Response.forbidden('Superuser role required');
        }
        if (!await authService.isUserActive(userId)) {
          return Response.forbidden('User deactivated');
        }
        if (tenantId != null && !await authService.isTenantActive(tenantId)) {
          return Response.forbidden('Tenant deactivated');
        }

        authenticatedRequest = request.change(
          context: {
            'inspector.userId': userId,
            'inspector.tenantId': tenantId,
            'inspector.role': role,
          },
        );
      } on JWTException {
        return Response.forbidden('Invalid authentication token');
      } catch (_) {
        return Response.internalServerError(body: 'Authentication error');
      }
      return innerHandler(authenticatedRequest);
    };
  };
}

Middleware localInspectorCors() {
  return (Handler innerHandler) {
    return (Request request) async {
      final origin = request.headers['origin'];
      final allowedOrigin = _isLoopbackOrigin(origin) ? origin : null;
      final headers = <String, String>{
        'Access-Control-Allow-Methods': 'GET, OPTIONS',
        'Access-Control-Allow-Headers':
            'Origin, Content-Type, Authorization, X-Local-Inspector-Token',
        'Cache-Control': 'no-store',
      };
      if (allowedOrigin != null) {
        headers['Access-Control-Allow-Origin'] = allowedOrigin;
        headers['Vary'] = 'Origin';
      }

      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final response = await innerHandler(request);
      return response.change(headers: {...headers, ...response.headers});
    };
  };
}

bool _isLoopbackOrigin(String? origin) {
  if (origin == null) return false;
  final uri = Uri.tryParse(origin);
  if (uri == null) return false;
  return uri.host == 'localhost' ||
      uri.host == '127.0.0.1' ||
      uri.host == '::1';
}
