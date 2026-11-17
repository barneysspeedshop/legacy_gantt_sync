class ClientInfo {
  final String userId;
  final String tenantId;
  final String role;
  final String connectionId;
  final Set<String> channels = {};
  // We don't store the WebSocketChannel here anymore to avoid circular dependencies if possible,
  // or we can keep it if needed. `bin/server.dart` stored it in a Map<Key, ClientInfo>.
  // The original definition was:
  // class ClientInfo {
  //   final String userId;
  //   final String tenantId;
  //   final String role;
  //   final String connectionId;
  //   final Set<String> channels = {};
  //   ClientInfo(this.userId, this.tenantId, this.role, this.connectionId);
  // }

  ClientInfo(this.userId, this.tenantId, this.role, this.connectionId);
}
