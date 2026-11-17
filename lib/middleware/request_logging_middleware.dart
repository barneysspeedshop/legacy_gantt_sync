import 'package:shelf/shelf.dart';

import '../utils/logger.dart';

Middleware requestLoggingMiddleware({
  void Function(Map<String, dynamic>)? writeLog,
}) {
  final log = writeLog ?? (data) => JsonLogger.info('HTTP_REQUEST', data);
  return (inner) => (request) async {
    final response = await inner(request);
    log({
      'method': request.method,
      'path': request.url.path,
      'status': response.statusCode,
    });
    return response;
  };
}
