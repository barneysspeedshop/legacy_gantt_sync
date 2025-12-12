import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';

class WebSocketService {
  final ApiService apiService;
  WebSocketChannel? _channel;
  final StreamController<void> _adminUpdatesController = StreamController.broadcast();
  final StreamController<void> _userUpdatesController = StreamController.broadcast();

  // Expose streams
  Stream<void> get adminUpdates => _adminUpdatesController.stream;
  Stream<void> get userUpdates => _userUpdatesController.stream;

  WebSocketService(this.apiService);

  Future<void> connect() async {
    final token = apiService.accessToken;
    if (token == null) {
      debugPrint('WS: No token, skipping connect');
      return;
    }

    // Normalize URL: http://localhost:8080 -> ws://localhost:8080/ws
    var uri = Uri.parse(apiService.baseUrl);
    var scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    var wsUrl = uri.replace(scheme: scheme, path: '/ws', queryParameters: {'token': token});

    debugPrint('WS: Connecting to $wsUrl');

    try {
      _channel = WebSocketChannel.connect(wsUrl);
      debugPrint('WS: Connection initiated');

      _channel!.stream.listen(
        (message) {
          debugPrint('WS: Received message: $message');
          try {
            final data = jsonDecode(message);
            final type = data['type'];

            if (type == 'TENANT_LIST_UPDATE') {
              debugPrint('WS: Dispatching TENANT_LIST_UPDATE');
              _adminUpdatesController.add(null);
            } else if (type == 'USER_LIST_UPDATE') {
              debugPrint('WS: Dispatching USER_LIST_UPDATE');
              _userUpdatesController.add(null);
            } else if (type == 'SUBSCRIBE_SUCCESS') {
              debugPrint('WS: Subscription confirmed for ${data['channel']}');
            } else {
              debugPrint('WS: Unknown message type: $type');
            }
          } catch (e) {
            debugPrint('WS Parse Error: $e');
          }
        },
        onError: (e) {
          debugPrint('WS Error: $e');
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('WS: Connection closed');
          if (_channel != null) {
            debugPrint('WS: Close Code: ${_channel!.closeCode}');
            debugPrint('WS: Close Reason: ${_channel!.closeReason}');
          }
          _channel = null;
          _scheduleReconnect();
        },
      );
    } catch (e) {
      debugPrint('WS Connection Failed: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    debugPrint('WS: Scheduling reconnect in 2 seconds...');
    Timer(const Duration(seconds: 2), () {
      if (!_isDisposed) connect();
    });
  }

  void subscribeToAdminUpdates() {
    if (_channel == null) {
      debugPrint('WS: Warn - Channel null, queuing or ignoring subscribe to admin_updates');
      return;
    }
    debugPrint('WS: Subscribing to admin_updates');
    try {
      _channel?.sink.add(jsonEncode({'type': 'subscribe', 'channel': 'admin_updates'}));
    } catch (e) {
      debugPrint('WS: Error sending subscribe: $e');
    }
  }

  void subscribeToTenantUsers(String tenantId) {
    if (_channel == null) {
      debugPrint('WS: Warn - Channel null, queuing or ignoring subscribe to tenant_users_$tenantId');
      return;
    }
    debugPrint('WS: Subscribing to tenant_users_$tenantId');
    try {
      _channel?.sink.add(jsonEncode({'type': 'subscribe', 'channel': 'tenant_users_$tenantId'}));
    } catch (e) {
      debugPrint('WS: Error sending subscribe: $e');
    }
  }

  bool _isDisposed = false;

  void dispose() {
    _isDisposed = true;
    _channel?.sink.close();
    _adminUpdatesController.close();
    _userUpdatesController.close();
  }
}
