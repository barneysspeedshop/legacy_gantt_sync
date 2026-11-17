import 'package:postgres_crdt/postgres_crdt.dart';

abstract class OperationHandler {
  Future<List<Map<String, dynamic>>> handle(
    CrdtExecutor executor,
    String tenantId,
    Map<String, dynamic> operationData,
    String timestamp,
  );
}

abstract class BaseOperationHandler implements OperationHandler {
  Map<String, dynamic> getAttributes(Map<String, dynamic> operationData) {
    var current = operationData;
    while (current.containsKey('data') && current['data'] is Map) {
      current = current['data'] as Map<String, dynamic>;
    }
    return current;
  }

  dynamic getValue(
    Map<String, dynamic> operationData,
    String key, [
    List<String>? aliases,
  ]) {
    final attributes = getAttributes(operationData);

    if (attributes.containsKey(key)) return attributes[key];
    if (aliases != null) {
      for (final alias in aliases) {
        if (attributes.containsKey(alias)) return attributes[alias];
      }
    }
    if (operationData.containsKey(key)) return operationData[key];
    if (aliases != null) {
      for (final alias in aliases) {
        if (operationData.containsKey(alias)) return operationData[alias];
      }
    }
    return null;
  }

  /// Helper to return empty list as default result
  Future<List<Map<String, dynamic>>> emptyResult() async => [];
}
