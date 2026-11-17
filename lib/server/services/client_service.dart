import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:legacy_gantt_sync/server/models/client_info.dart';
import 'package:legacy_gantt_sync/server/services/pub_sub_service.dart';
import 'package:legacy_gantt_sync/server/models/pub_sub_message.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart'
    show ProtobufMapper;

class ClientService {
  final Map<WebSocketChannel, ClientInfo> _clientInfos = {};
  final Map<String, List<WebSocketChannel>> _channels = {};
  final PubSubService pubSubService;

  ClientService(this.pubSubService);

  void startListening() {
    pubSubService.getStream()?.listen((message) {
      if (message is List) {
        try {
          final pubSubMsg = PubSubMessage.fromList(message);

          // Redis PubSub control messages:
          // [subscribe, channel, count]
          // [unsubscribe, channel, count]
          // [message, channel, payload]
          if (pubSubMsg.type == 'subscribe' ||
              pubSubMsg.type == 'unsubscribe') {
            // These are control messages, safe to ignore
            return;
          }

          if (pubSubMsg.type != 'message') return;

          final channelName = pubSubMsg.channelName;
          final payload = pubSubMsg.payload;

          try {
            final decoded = jsonDecode(payload);
            if (decoded is Map<String, dynamic>) {
              final originConnectionId = decoded['originConnectionId'];

              final subscribers = _channels[channelName];
              if (subscribers != null) {
                // Convert the JSON payload back to a binary Protobuf for the WebSocket clients
                final protobufBytes = ProtobufMapper.toProtobuf(
                  decoded,
                ).writeToBuffer();

                for (final client in subscribers) {
                  final info = _clientInfos[client];
                  if (info?.connectionId != originConnectionId) {
                    client.sink.add(protobufBytes);
                  }
                }
              }
            }
          } catch (e) {
            JsonLogger.error('REDIS_MSG_DECODE_ERROR', {
              'error': e.toString(),
              'channel': channelName,
            });
          }
        } catch (e) {
          JsonLogger.error('REDIS_MSG_FORMAT_ERROR', {
            'error': e.toString(),
            'raw': message,
          });
        }
      }
    });
  }

  void addClient(WebSocketChannel channel, ClientInfo info) {
    _clientInfos[channel] = info;
  }

  void removeClient(WebSocketChannel channel) {
    final info = _clientInfos[channel];
    if (info != null) {
      for (final channelId in info.channels) {
        final list = _channels[channelId];
        if (list != null) {
          list.remove(channel);
          if (list.isEmpty) {
            pubSubService.unsubscribe([channelId]);
            _channels.remove(channelId);
          }
        }
      }
      _clientInfos.remove(channel);
    }
  }

  ClientInfo? getClient(WebSocketChannel channel) => _clientInfos[channel];

  Iterable<ClientInfo> get allClients => _clientInfos.values;

  List<WebSocketChannel> getSubscribers(String channelName) {
    return _channels[channelName] ?? [];
  }

  void subscribe(WebSocketChannel channel, String channelName) {
    final info = _clientInfos[channel];
    if (info != null) {
      info.channels.add(channelName);
      final list = _channels.putIfAbsent(channelName, () => []);
      if (!list.contains(channel)) list.add(channel);

      if (list.length == 1) {
        pubSubService.subscribe([channelName]);
      }
    }
  }

  int getActiveConnectionsCount(String tenantId) {
    return _clientInfos.values.where((c) => c.tenantId == tenantId).length;
  }

  bool isUserConnected(String userId) {
    return _clientInfos.values.any((c) => c.userId == userId);
  }

  Future<int> kickUser(String userId, int closeCode, String reason) async {
    final connectionsToKick = _clientInfos.entries
        .where((entry) => entry.value.userId == userId)
        .toList();
    for (final entry in connectionsToKick) {
      await entry.key.sink.close(closeCode, reason);
    }
    return connectionsToKick.length;
  }

  Future<int> kickTenant(String tenantId, int closeCode, String reason) async {
    final connectionsToKick = _clientInfos.entries
        .where((entry) => entry.value.tenantId == tenantId)
        .toList();
    for (final entry in connectionsToKick) {
      await entry.key.sink.close(closeCode, reason);
    }
    return connectionsToKick.length;
  }
}
