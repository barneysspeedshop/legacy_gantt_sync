import 'dart:async';
import 'dart:io';
import 'package:redis/redis.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';

class PubSubService {
  Command? _redisCommand;
  PubSub? _redisPubSub;

  Future<void> init(String host, int port) async {
    // Get password from Env (Docker Swarm)
    final password = Platform.environment['REDIS_PASSWORD'];

    try {
      // 1. Connection for Publishing
      final conn1 = RedisConnection();
      _redisCommand = await conn1.connect(host, port);
      if (password != null && password.isNotEmpty) {
        await _redisCommand!.send_object(['AUTH', password]);
      }
      JsonLogger.info('REDIS_PUB_CONNECTED', {'host': host});

      // 2. Connection for Subscribing
      final conn2 = RedisConnection();
      final cmd2 = await conn2.connect(host, port);
      if (password != null && password.isNotEmpty) {
        await cmd2.send_object(['AUTH', password]);
      }
      _redisPubSub = PubSub(cmd2);
      JsonLogger.info('REDIS_SUB_CONNECTED', {'host': host});
    } catch (e) {
      JsonLogger.error('REDIS_CONNECT_FAIL', {'error': e.toString()});
      // In production, you might want to rethrow or retry here
    }
  }

  Stream<dynamic>? getStream() {
    return _redisPubSub?.getStream();
  }

  void subscribe(List<String> channels) {
    _redisPubSub?.subscribe(channels);
  }

  void unsubscribe(List<String> channels) {
    _redisPubSub?.unsubscribe(channels);
  }

  void publish(String channel, String message) {
    _redisCommand?.send_object(['PUBLISH', channel, message]);
  }
}
