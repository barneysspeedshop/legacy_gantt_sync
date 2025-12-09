import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    JsonLogger.error('INVALID_USAGE', {'message': 'Usage: dart bin/generate_token.dart <user_id> [tenant_id]'});
    exit(1);
  }

  final userId = args[0];
  final tenantId = args.length > 1 ? args[1] : 'default_tenant';
  final secret = Platform.environment['JWT_SECRET'];

  if (secret == null) {
    JsonLogger.error('CONFIG_ERROR', {'message': 'JWT_SECRET environment variable is not set.'});
    exit(1);
  }

  final jwt = JWT({
    'sub': userId,
    'tenant_id': tenantId,
    'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'exp': DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/ 1000,
  });

  final token = jwt.sign(SecretKey(secret));

  JsonLogger.info('TOKEN_GENERATED', {
    'user_id': userId,
    'tenant_id': tenantId,
    'token': token, // Logging token for convenience in this CLI tool, be careful in logs
  });
}
