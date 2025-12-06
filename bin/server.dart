import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// In-memory store of operations
final List<Map<String, dynamic>> _operations = [];
final List<WebSocketChannel> _clients = [];

void main(List<String> args) async {
  // Use any available host or container IP (usually 0.0.0.0).
  // Use a default port or an environment variable.
  final port = int.parse(Platform.environment['LEGACY_GANTT_SYNC_PORT'] ?? '8080');

  final app = Router();

  final wsHandler = webSocketHandler((webSocket, _) {
    final channel = webSocket;
    _clients.add(channel);
    print('Client connected. Total clients: ${_clients.length}');

    // Send initial state (all operations history)
    for (var op in _operations) {
      channel.sink.add(jsonEncode(op));
    }

    channel.stream.listen(
      (message) {
        print('Received message: $message');
        try {
          final data = jsonDecode(message as String) as Map<String, dynamic>;

          // Store operation
          // In a real app, we would validate it against the CRDT schema
          _operations.add(data);

          // Broadcast to all other clients
          for (var client in _clients) {
            if (client != channel) {
              client.sink.add(message);
            }
          }
        } catch (e) {
          print('Error processing message: $e');
        }
      },
      onDone: () {
        _clients.remove(channel);
        print('Client disconnected. Total clients: ${_clients.length}');
      },
      onError: (error) {
        _clients.remove(channel);
        print('Client error: $error');
      },
    );
  });

  app.get('/ws', (Request request) {
    final jwtSecret = Platform.environment['JWT_SECRET'];
    if (jwtSecret != null) {
      bool authenticated = false;
      String? token;

      // Check Header
      final authHeader = request.headers['Authorization'];
      if (authHeader != null && authHeader.startsWith('Bearer ')) {
        token = authHeader.substring(7);
      }

      // Check Query Parameter
      token ??= request.url.queryParameters['token'];

      if (token != null) {
        try {
          JWT.verify(token, SecretKey(jwtSecret));
          authenticated = true;
        } catch (e) {
          print('Token verification failed: $e');
        }
      }

      if (!authenticated) {
        print('Rejected connection: Invalid or missing token');
        return Response.forbidden('Unauthorized');
      }
    }
    return wsHandler(request);
  });

  // Health check
  app.get('/health', (Request request) {
    return Response.ok('OK');
  });

  final handler = Pipeline().addMiddleware(logRequests()).addHandler(app.call);

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  print('Serving at http://${server.address.host}:${server.port}');
}
