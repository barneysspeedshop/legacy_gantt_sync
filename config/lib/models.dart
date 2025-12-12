class Tenant {
  final String id;
  final String name;
  final bool isActive;
  final int activeConnections;
  final int userCount;

  Tenant({required this.id, required this.name, required this.isActive, required this.activeConnections, required this.userCount});

  factory Tenant.fromJson(Map<String, dynamic> json) {
    return Tenant(
      id: json['id'],
      name: json['name'],
      isActive: json['isActive'] ?? true, // Default to true if missing
      activeConnections: json['activeConnections'] ?? 0,
      userCount: json['userCount'] ?? 0,
    );
  }
}

class User {
  final String id;
  final String username;
  final String role;
  final String tenantId;
  final bool isActive;
  final bool isConnected;

  User({required this.id, required this.username, required this.role, required this.tenantId, required this.isActive, required this.isConnected});

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'],
      username: json['username'],
      role: json['role'] ?? 'user',
      tenantId: json['tenantId'],
      isActive: json['isActive'] ?? true,
      isConnected: json['isConnected'] ?? false,
    );
  }
}
