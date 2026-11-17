import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'database_inspector_screen.dart';
import 'websocket_service.dart';
import 'models.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // We initialize with a default, but it will be updated by the LoginScreen
  final prefs = await SharedPreferences.getInstance();
  // Remove credentials persisted by older versions; sessions now stay in memory.
  for (final key in [
    'accessToken',
    'refreshToken',
    'adminSecret',
    'localInspectorToken',
  ]) {
    await prefs.remove(key);
  }
  final apiService = ApiService('http://127.0.0.1', prefs);
  final webSocketService = WebSocketService(apiService);

  runApp(ConfigApp(apiService: apiService, webSocketService: webSocketService));
}

class ConfigApp extends StatefulWidget {
  final ApiService apiService;
  final WebSocketService webSocketService;

  const ConfigApp({
    super.key,
    required this.apiService,
    required this.webSocketService,
  });

  @override
  State<ConfigApp> createState() => ConfigAppState();

  static ConfigAppState of(BuildContext context) =>
      context.findAncestorStateOfType<ConfigAppState>()!;
}

class ConfigAppState extends State<ConfigApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.light
          ? ThemeMode.dark
          : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Legacy Gantt Config',
      theme: ThemeData(primarySwatch: Colors.blue),
      darkTheme: ThemeData.dark(),
      themeMode: _themeMode,
      home: LoginScreen(
        apiService: widget.apiService,
        webSocketService: widget.webSocketService,
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  final ApiService apiService;
  final WebSocketService webSocketService;

  const LoginScreen({
    super.key,
    required this.apiService,
    required this.webSocketService,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _urlController = TextEditingController(text: 'http://localhost:8080');
  final _inspectorUrlController = TextEditingController(
    text: 'http://127.0.0.1:8787',
  );
  final _inspectorTokenController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Load saved values if available
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = widget.apiService.prefs;
    final savedUrl = prefs.getString('server_url');
    final savedInspectorUrl = prefs.getString('inspector_url');

    if (savedUrl != null) _urlController.text = savedUrl;
    if (savedInspectorUrl != null) {
      _inspectorUrlController.text = savedInspectorUrl;
    }
  }

  Future<void> _login() async {
    setState(() => _isLoading = true);

    // Update API Service URL
    widget.apiService.baseUrl = _urlController.text;

    // Save settings
    await widget.apiService.prefs.setString('server_url', _urlController.text);
    await widget.apiService.prefs.setString(
      'inspector_url',
      _inspectorUrlController.text,
    );
    widget.apiService.localInspectorToken = _inspectorTokenController.text;
    final success = await widget.apiService.login(
      _usernameController.text,
      _passwordController.text,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      if (!mounted) return;
      await widget.webSocketService.connect();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DashboardScreen(
            apiService: widget.apiService,
            webSocketService: widget.webSocketService,
          ),
        ),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Login Failed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(labelText: 'Server URL'),
              ),
              TextField(
                controller: _inspectorUrlController,
                decoration: const InputDecoration(
                  labelText: 'Local Inspector URL',
                ),
              ),
              TextField(
                controller: _inspectorTokenController,
                decoration: const InputDecoration(
                  labelText: 'Local Inspector Token',
                ),
                obscureText: true,
              ),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
              const SizedBox(height: 20),
              _isLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _login,
                      child: const Text('Login'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  final ApiService apiService;
  final WebSocketService webSocketService;

  const DashboardScreen({
    super.key,
    required this.apiService,
    required this.webSocketService,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.brightness_6),
            onPressed: () => ConfigApp.of(context).toggleTheme(),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await apiService.logout();
              webSocketService.dispose();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LoginScreen(
                      apiService: apiService,
                      webSocketService: webSocketService,
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Manage Tenants'),
            subtitle: const Text('View, Create, and Manage Tenants'),
            leading: const Icon(Icons.business),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TenantListScreen(
                    apiService: apiService,
                    webSocketService: webSocketService,
                  ),
                ),
              );
            },
          ),
          ListTile(
            title: const Text('Database Inspector'),
            subtitle: const Text('Browse application tables and sync state'),
            leading: const Icon(Icons.storage),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      DatabaseInspectorScreen(apiService: apiService),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class TenantListScreen extends StatefulWidget {
  final ApiService apiService;
  final WebSocketService webSocketService;

  const TenantListScreen({
    super.key,
    required this.apiService,
    required this.webSocketService,
  });

  @override
  State<TenantListScreen> createState() => _TenantListScreenState();
}

class _TenantListScreenState extends State<TenantListScreen> {
  late Future<List<Tenant>> _tenantsFuture;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _tenantsFuture = widget.apiService.getTenants();
    _subscribe();
  }

  void _subscribe() {
    widget.webSocketService.subscribeToAdminUpdates();
    _subscription = widget.webSocketService.adminUpdates.listen((_) {
      debugPrint('TenantListScreen: Received update, refreshing...');
      _refresh();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _refresh() {
    debugPrint('TenantListScreen: _refresh called');
    if (!mounted) {
      debugPrint('TenantListScreen: not mounted, skipping');
      return;
    }
    setState(() {
      _tenantsFuture = widget.apiService.getTenants();
    });
  }

  void _showCreateDialog() {
    final nameController = TextEditingController();
    final adminUserController = TextEditingController();
    final adminPassController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Tenant'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Tenant Name'),
            ),
            TextField(
              controller: adminUserController,
              decoration: const InputDecoration(labelText: 'Admin Username'),
            ),
            TextField(
              controller: adminPassController,
              decoration: const InputDecoration(labelText: 'Admin Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await widget.apiService.createTenant(
                  nameController.text,
                  adminUserController.text,
                  adminPassController.text,
                );
                if (!mounted) return;
                if (ctx.mounted) Navigator.pop(ctx);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Tenant Created')));
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Error: $e')));
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tenants')),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateDialog,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<Tenant>>(
        future: _tenantsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              _subscription == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final tenants = snapshot.data!;
          return ListView.builder(
            itemCount: tenants.length,
            itemBuilder: (context, index) {
              final tenant = tenants[index];
              return ListTile(
                leading: Icon(
                  Icons.computer,
                  color: tenant.isActive ? null : Colors.grey,
                ),
                title: Text(
                  tenant.name,
                  style: TextStyle(
                    decoration: tenant.isActive
                        ? null
                        : TextDecoration.lineThrough,
                    color: tenant.isActive ? null : Colors.grey,
                  ),
                ),
                subtitle: Text(
                  'ID: ${tenant.id}, Users: ${tenant.userCount}, Active Connections: ${tenant.activeConnections} ${tenant.isActive ? "" : "(Revoked)"}',
                ),
                onTap: () {
                  if (!tenant.isActive) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => UserListScreen(
                        tenantId: tenant.id,
                        apiService: widget.apiService,
                        webSocketService: widget.webSocketService,
                      ),
                    ),
                  );
                },
                trailing: (tenant.id == 'system')
                    ? const SizedBox.shrink()
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!tenant.isActive)
                            IconButton(
                              icon: const Icon(
                                Icons.restore,
                                color: Colors.green,
                              ),
                              tooltip: 'Restore Tenant',
                              onPressed: () async {
                                await widget.apiService.undeleteTenant(
                                  tenant.id,
                                );
                              },
                            ),
                          if (tenant.isActive)
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              tooltip: 'Revoke Tenant',
                              onPressed: () async {
                                await widget.apiService.deleteTenant(tenant.id);
                              },
                            ),
                        ],
                      ),
              );
            },
          );
        },
      ),
    );
  }
}

class UserListScreen extends StatefulWidget {
  final ApiService apiService;
  final WebSocketService webSocketService;
  final String tenantId;

  const UserListScreen({
    super.key,
    required this.apiService,
    required this.webSocketService,
    required this.tenantId,
  });

  @override
  State<UserListScreen> createState() => _UserListScreenState();
}

class _UserListScreenState extends State<UserListScreen> {
  late Future<List<User>> _usersFuture;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _usersFuture = widget.apiService.getUsersByTenant(widget.tenantId);
    _subscribe();
  }

  void _subscribe() {
    widget.webSocketService.subscribeToTenantUsers(widget.tenantId);
    _subscription = widget.webSocketService.userUpdates.listen((_) {
      debugPrint('UserListScreen: Received update, refreshing...');
      _refresh();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _refresh() {
    debugPrint('UserListScreen: _refresh called');
    if (!mounted) {
      debugPrint('UserListScreen: not mounted, skipping');
      return;
    }
    setState(() {
      _usersFuture = widget.apiService.getUsersByTenant(widget.tenantId);
    });
  }

  void _showCreateDialog() {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    String role = 'user';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (sbContext, setState) => AlertDialog(
          title: const Text('Create User'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: usernameController,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              TextField(
                controller: passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              DropdownButton<String>(
                value: role,
                items: [
                  const DropdownMenuItem(value: 'user', child: Text('User')),
                  const DropdownMenuItem(
                    value: 'tenant_admin',
                    child: Text('Tenant Admin'),
                  ),
                  if (widget.tenantId == 'system')
                    const DropdownMenuItem(
                      value: 'superuser',
                      child: Text('Superuser'),
                    ),
                ],
                onChanged: (val) => setState(() => role = val!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                try {
                  await widget.apiService.createUser(
                    widget.tenantId,
                    usernameController.text,
                    passwordController.text,
                    role,
                  );
                  if (!mounted) return;
                  if (ctx.mounted) Navigator.pop(ctx);
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('User Created')));
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Users (${widget.tenantId})')),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateDialog,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<User>>(
        future: _usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              _subscription == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final users = snapshot.data!;
          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, index) {
              final user = users[index];
              IconData icon;
              if (user.role == 'superuser') {
                icon = Icons.auto_fix_high; // Wizard-y
              } else if (user.role == 'tenant_admin') {
                icon = Icons.local_police; // Badge/Police
              } else {
                icon = Icons.person; // Regular person
              }

              return ListTile(
                leading: Icon(icon, color: user.isActive ? null : Colors.grey),
                title: Row(
                  children: [
                    Text(
                      user.username,
                      style: TextStyle(
                        decoration: user.isActive
                            ? null
                            : TextDecoration.lineThrough,
                        color: user.isActive ? null : Colors.grey,
                      ),
                    ),
                    if (user.isConnected) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.link, color: Colors.green, size: 20),
                    ],
                  ],
                ),
                subtitle: Text(
                  'Role: ${user.role} ${user.isActive ? "" : "(Revoked)"}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (user.isConnected &&
                        user.username !=
                            'superuser') // Don't kick yourself superuser easily here, or just let them
                      IconButton(
                        icon: const Icon(
                          Icons.exit_to_app,
                          color: Colors.orange,
                        ),
                        tooltip: 'Kick User',
                        onPressed: () async {
                          await widget.apiService.kickUser(user.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('User Kicked')),
                            );
                          }
                        },
                      ),
                    (user.username == 'superuser' && user.tenantId == 'system')
                        ? const SizedBox.shrink() // Protect superuser
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!user.isActive)
                                IconButton(
                                  icon: const Icon(
                                    Icons.restore,
                                    color: Colors.green,
                                  ),
                                  tooltip: 'Restore User',
                                  onPressed: () async {
                                    await widget.apiService.undeleteUser(
                                      user.id,
                                    );
                                  },
                                ),
                              if (user.isActive)
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                  ),
                                  tooltip: 'Revoke User',
                                  onPressed: () async {
                                    await widget.apiService.revokeUser(user.id);
                                  },
                                ),
                            ],
                          ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
