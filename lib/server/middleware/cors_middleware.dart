import 'package:shelf/shelf.dart';

Middleware corsHeaders() {
  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods':
                'GET, POST, PUT, DELETE, OPTIONS, PATCH',
            'Access-Control-Allow-Headers':
                'Origin, Content-Type, Authorization, X-Requested-With',
          },
        );
      }
      final response = await innerHandler(request);
      return response.change(
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods':
              'GET, POST, PUT, DELETE, OPTIONS, PATCH',
          'Access-Control-Allow-Headers':
              'Origin, Content-Type, Authorization, X-Requested-With',
        },
      );
    };
  };
}
