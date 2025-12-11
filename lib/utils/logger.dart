import 'dart:convert';
import 'dart:io';

class JsonLogger {
  static void _log(String level, String event, [Map<String, dynamic>? data]) {
    final logEntry = {
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'event': event,
      if (data != null) 'data': data,
    };
    stdout.writeln(jsonEncode(logEntry));
  }

  static void info(String event, [Map<String, dynamic>? data]) {
    _log('INFO', event, data);
  }

  static void warn(String event, [Map<String, dynamic>? data]) {
    _log('WARN', event, data);
  }

  static void error(String event, [Map<String, dynamic>? data]) {
    _log('ERROR', event, data);
  }
}
