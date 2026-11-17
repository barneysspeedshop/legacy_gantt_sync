class Tenant {
  final String id;
  final String name;
  final bool isActive;

  Tenant({required this.id, required this.name, required this.isActive});
}

class User {
  final String id;
  final String username;
  final String role;
  final String tenantId;
  final bool isActive;

  User({
    required this.id,
    required this.username,
    required this.role,
    required this.tenantId,
    required this.isActive,
  });
}
