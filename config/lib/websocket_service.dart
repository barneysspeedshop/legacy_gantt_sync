import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';

class WebSocketService {
  final ApiService apiService;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  final Set<String> _subscriptions = {};
  bool _isConnected = false;
  final StreamController<void> _adminUpdatesController =
      StreamController.broadcast();
  final StreamController<void> _userUpdatesController =
      StreamController.broadcast();

  Stream<void> get adminUpdates => _adminUpdatesController.stream;
  Stream<void> get userUpdates => _userUpdatesController.stream;

  WebSocketService(this.apiService);

  Future<void> connect() async {
    if (_isDisposed || _channel != null) return;
    _reconnectTimer?.cancel();
    final token = apiService.accessToken;
    if (token == null) {
      debugPrint('WS: No token, skipping connect');
      return;
    }

    var uri = Uri.parse(apiService.baseUrl);
    var scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    var wsUrl = uri.replace(
      scheme: scheme,
      path: '/ws',
      queryParameters: {'token': token},
    );

    debugPrint('WS: Connecting');

    try {
      final channel = WebSocketChannel.connect(wsUrl);
      _channel = channel;
      debugPrint('WS: Connection initiated');

      _subscription = channel.stream.listen(
        (message) {
          debugPrint('WS: Message received');
          try {
            final data = ProtocolMessage.fromBuffer(message as List<int>);
            final type = data.type;

            if (type == 'TENANT_LIST_UPDATE') {
              debugPrint('WS: Dispatching TENANT_LIST_UPDATE');
              _adminUpdatesController.add(null);
            } else if (type == 'USER_LIST_UPDATE') {
              debugPrint('WS: Dispatching USER_LIST_UPDATE');
              _userUpdatesController.add(null);
            } else if (type == 'SUBSCRIBE_SUCCESS') {
              debugPrint('WS: Subscription confirmed for ${data.channel}');
            } else {
              debugPrint('WS: Unknown message type: $type');
            }
          } catch (e) {
            debugPrint('WS: Message could not be decoded');
          }
        },
        onError: (e) {
          debugPrint('WS: Connection error');
          _connectionClosed(channel);
        },
        onDone: () {
          debugPrint('WS: Connection closed');
          _connectionClosed(channel);
        },
      );
      await channel.ready;
      if (_isDisposed || _channel != channel) return;
      _isConnected = true;
      for (final name in _subscriptions) {
        _sendSubscription(name);
      }
    } catch (e) {
      debugPrint('WS: Connection failed');
      _isConnected = false;
      _channel = null;
      _scheduleReconnect();
    }
  }

  void _connectionClosed(WebSocketChannel channel) {
    if (_channel != channel) return;
    _isConnected = false;
    _channel = null;
    unawaited(_subscription?.cancel());
    unawaited(channel.sink.close());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_isDisposed || (_reconnectTimer?.isActive ?? false)) return;
    debugPrint('WS: Scheduling reconnect in 2 seconds...');
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!_isDisposed) connect();
    });
  }

  void subscribeToAdminUpdates() {
    _subscribe('admin_updates');
  }

  void subscribeToTenantUsers(String tenantId) {
    _subscribe('tenant_users_$tenantId');
  }

  void _subscribe(String channel) {
    if (_isDisposed) return;
    if (_subscriptions.add(channel) && _isConnected) {
      _sendSubscription(channel);
    }
  }

  void _sendSubscription(String channel) {
    _channel!.sink.add(
      ProtobufMapper.toProtobuf({
        'type': 'subscribe',
        'channel': channel,
      }).writeToBuffer(),
    );
  }

  bool _isDisposed = false;

  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    unawaited(_subscription?.cancel());
    _channel?.sink.close();
    _adminUpdatesController.close();
    _userUpdatesController.close();
  }
}
