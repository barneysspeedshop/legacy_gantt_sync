import 'dart:async';

import 'package:legacy_gantt_sync/utils/logger.dart';

/// Retries an asynchronous [operation] indefinetely until it succeeds.
///
/// [operation] The async function to execute.
/// [maxDelay] The maximum delay between retries. Defaults to 30 seconds.
/// [initialDelay] The initial delay before the first retry. Defaults to 1 second.
/// [multiplier] The factor by which the delay increases after each failure. Defaults to 2.0.
/// [description] A description of the operation for logging purposes.
Future<T> retryForever<T>(
  Future<T> Function() operation, {
  Duration maxDelay = const Duration(seconds: 30),
  Duration initialDelay = const Duration(seconds: 1),
  double multiplier = 2.0,
  String description = 'Operation',
}) async {
  Duration currentDelay = initialDelay;

  while (true) {
    try {
      return await operation();
    } catch (e) {
      JsonLogger.warn('RETRY_OPERATION_FAILED', {'operation': description, 'error': e.toString(), 'next_retry_delay_ms': currentDelay.inMilliseconds});
      // Optional: Log stack trace if it's a critical or unexpected error type
      // but for connection retries, simple warning is usually enough.

      await Future.delayed(currentDelay);

      // Calculate next delay
      final nextMilliseconds = (currentDelay.inMilliseconds * multiplier).round();
      currentDelay = Duration(milliseconds: nextMilliseconds);

      if (currentDelay > maxDelay) {
        currentDelay = maxDelay;
      }
    }
  }
}
