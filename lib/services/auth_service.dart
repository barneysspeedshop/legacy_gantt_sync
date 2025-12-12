import 'package:bcrypt/bcrypt.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:postgres/postgres.dart';
import '../models/auth_models.dart';
import '../utils/logger.dart';

class AuthService {
  final Future<Connection> Function() _connectionFactory;
  Connection? _connection;
  final String _jwtSecret;

  AuthService(this._connectionFactory, this._jwtSecret);

  Future<Connection> _getConnection() async {
    if (_connection != null && _connection!.isOpen) {
      return _connection!;
    }
    try {
      JsonLogger.info('AUTH_DB_CONNECTING', {});
      _connection = await _connectionFactory();
      return _connection!;
    } catch (e) {
      JsonLogger.error('AUTH_DB_CONNECT_FAIL', {'error': e.toString()});
      rethrow;
    }
  }

  /// Executes an operation with automatic retry on connection failure.
  Future<T> _execute<T>(Future<T> Function(Connection c) action) async {
    try {
      final conn = await _getConnection();
      return await action(conn);
    } catch (e) {
      final isNetworkError =
          e.toString().contains('SocketException') || e.toString().contains('Connection closed') || (e is ServerException && e.severity == Severity.error);

      if (isNetworkError) {
        JsonLogger.warn('AUTH_DB_RETRY', {'error': e.toString()});
        // Force reconnection
        _connection = null; // Discard old connection
        final conn = await _getConnection();
        return await action(conn);
      }
      rethrow;
    }
  }

  Future<void> init() async {
    await _execute((c) async {
      await c.execute('CREATE SCHEMA IF NOT EXISTS auth');

      await c.execute('''
        CREATE TABLE IF NOT EXISTS auth.tenants (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          is_active BOOLEAN DEFAULT TRUE,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ''');

      await c.execute('''
        CREATE TABLE IF NOT EXISTS auth.users (
          id TEXT PRIMARY KEY,
          username TEXT UNIQUE NOT NULL,
          password_hash TEXT NOT NULL,
          role TEXT NOT NULL,
          tenant_id TEXT REFERENCES auth.tenants(id),
          is_active BOOLEAN DEFAULT TRUE,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ''');

      await c.execute('''
        CREATE TABLE IF NOT EXISTS auth.refresh_tokens (
          token_hash TEXT PRIMARY KEY,
          user_id TEXT REFERENCES auth.users(id),
          expires_at TIMESTAMP NOT NULL,
          is_revoked BOOLEAN DEFAULT FALSE
        )
      ''');
    });

    JsonLogger.info('AUTH_DB_INIT', {'status': 'success'});
  }

  Future<Tenant> registerTenant(String name, String adminUsername, String adminPassword) async {
    final tenantId = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');

    // Start transaction
    return await _execute(
      (c) => c.runTx((ctx) async {
        await ctx.execute(Sql.named('INSERT INTO auth.tenants (id, name) VALUES (@id, @name)'), parameters: {'id': tenantId, 'name': name});

        final passwordHash = BCrypt.hashpw(adminPassword, BCrypt.gensalt());
        final userId = '$adminUsername@$tenantId'; // Simple unique ID strategy or UUID

        await ctx.execute(
          Sql.named('INSERT INTO auth.users (id, username, password_hash, role, tenant_id, is_active) VALUES (@id, @username, @hash, @role, @tenantId, true)'),
          parameters: {'id': userId, 'username': adminUsername, 'hash': passwordHash, 'role': 'tenant_admin', 'tenantId': tenantId},
        );

        return Tenant(id: tenantId, name: name, isActive: true);
      }),
    );
  }

  Future<User> registerUser(String tenantId, String username, String password, String role) async {
    final passwordHash = BCrypt.hashpw(password, BCrypt.gensalt());
    // Ensure username is unique enough or scoped?
    // For simplicity, username is globally unique in table key, but maybe scoped to tenant logically?
    // Database 'username' field is unique.

    final userId = '$username@$tenantId'; // UUID preferred usually, but this is readable for now

    await _execute(
      (c) => c.execute(
        Sql.named('INSERT INTO auth.users (id, username, password_hash, role, tenant_id, is_active) VALUES (@id, @username, @hash, @role, @tenantId, true)'),
        parameters: {'id': userId, 'username': username, 'hash': passwordHash, 'role': role, 'tenantId': tenantId},
      ),
    );

    return User(id: userId, username: username, role: role, tenantId: tenantId, isActive: true);
  }

  Future<Map<String, String>> login(String username, String password) async {
    return await _execute((c) async {
      final result = await c.execute(
        Sql.named('SELECT id, password_hash, role, tenant_id, is_active FROM auth.users WHERE username = @username'),
        parameters: {'username': username},
      );

      if (result.isEmpty) {
        throw Exception('Invalid credentials');
      }

      final row = result.first;
      final hash = row[1] as String;
      final isActive = row[4] as bool;

      if (!isActive) {
        throw Exception('User is deactivated');
      }

      if (!BCrypt.checkpw(password, hash)) {
        throw Exception('Invalid credentials');
      }

      final userId = row[0] as String;
      final role = row[2] as String;
      final tenantId = row[3] as String;

      // Check tenant active
      final tenantResult = await c.execute(Sql.named('SELECT is_active FROM auth.tenants WHERE id = @id'), parameters: {'id': tenantId});

      if (tenantResult.isEmpty || !(tenantResult.first[0] as bool)) {
        throw Exception('Tenant is deactivated or invalid');
      }

      final accessToken = _generateAccessToken(userId, tenantId, role);
      // TODO: Implement refresh token logic if needed, simplfying to just access token for first pass

      return {'accessToken': accessToken};
    });
  }

  String _generateAccessToken(String userId, String tenantId, String role) {
    final jwt = JWT({
      'sub': userId,
      'tenant_id': tenantId,
      'role': role,
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    });
    return jwt.sign(SecretKey(_jwtSecret));
  }

  Future<void> revokeUser(String userId) async {
    await _execute((c) => c.execute(Sql.named('UPDATE auth.users SET is_active = false WHERE id = @id'), parameters: {'id': userId}));
  }

  Future<void> undeleteUser(String userId) async {
    await _execute((c) => c.execute(Sql.named('UPDATE auth.users SET is_active = true WHERE id = @id'), parameters: {'id': userId}));
  }

  Future<void> revokeTenant(String tenantId) async {
    await _execute((c) => c.execute(Sql.named('UPDATE auth.tenants SET is_active = false WHERE id = @id'), parameters: {'id': tenantId}));
  }

  Future<void> undeleteTenant(String tenantId) async {
    await _execute((c) => c.execute(Sql.named('UPDATE auth.tenants SET is_active = true WHERE id = @id'), parameters: {'id': tenantId}));
  }

  Future<bool> isUserActive(String userId) async {
    return await _execute((c) async {
      final result = await c.execute(Sql.named('SELECT is_active FROM auth.users WHERE id = @id'), parameters: {'id': userId});
      return result.isNotEmpty && (result.first[0] as bool);
    });
  }

  Future<bool> isTenantActive(String tenantId) async {
    return await _execute((c) async {
      final result = await c.execute(Sql.named('SELECT is_active FROM auth.tenants WHERE id = @id'), parameters: {'id': tenantId});
      return result.isNotEmpty && (result.first[0] as bool);
    });
  }

  Future<List<Tenant>> getAllTenants() async {
    return await _execute((c) async {
      final result = await c.execute('SELECT id, name, is_active FROM auth.tenants');
      return result.map((row) => Tenant(id: row[0] as String, name: row[1] as String, isActive: row[2] as bool)).toList();
    });
  }

  Future<List<User>> getUsersByTenant(String tenantId) async {
    return await _execute((c) async {
      final result = await c.execute(
        Sql.named('SELECT id, username, role, tenant_id, is_active FROM auth.users WHERE tenant_id = @tenantId'),
        parameters: {'tenantId': tenantId},
      );
      return result
          .map((row) => User(id: row[0] as String, username: row[1] as String, role: row[2] as String, tenantId: row[3] as String, isActive: row[4] as bool))
          .toList();
    });
  }

  Future<int> getUserCount(String tenantId) async {
    return await _execute((c) async {
      final result = await c.execute(Sql.named('SELECT COUNT(*) FROM auth.users WHERE tenant_id = @tenantId'), parameters: {'tenantId': tenantId});
      return result.first[0] as int;
    });
  }

  Future<Tenant?> getTenant(String tenantId) async {
    return await _execute((c) async {
      final result = await c.execute(Sql.named('SELECT id, name, is_active FROM auth.tenants WHERE id = @id'), parameters: {'id': tenantId});
      if (result.isEmpty) return null;
      final row = result.first;
      return Tenant(id: row[0] as String, name: row[1] as String, isActive: row[2] as bool);
    });
  }

  Future<User?> getUser(String userId) async {
    return await _execute((c) async {
      final result = await c.execute(Sql.named('SELECT id, username, role, tenant_id, is_active FROM auth.users WHERE id = @id'), parameters: {'id': userId});
      if (result.isEmpty) return null;
      final row = result.first;
      return User(id: row[0] as String, username: row[1] as String, role: row[2] as String, tenantId: row[3] as String, isActive: row[4] as bool);
    });
  }

  Future<void> ensureSuperuser(String username, String password) async {
    final tenantId = 'system';
    // Ensure system tenant exists
    await _execute((c) async {
      await c.execute(
        Sql.named("INSERT INTO auth.tenants (id, name, is_active) VALUES (@id, 'System', true) ON CONFLICT (id) DO NOTHING"),
        parameters: {'id': tenantId},
      );

      final passwordHash = BCrypt.hashpw(password, BCrypt.gensalt());
      final userId = '$username@$tenantId';

      // Upsert superuser
      await c.execute(
        Sql.named(
          'INSERT INTO auth.users (id, username, password_hash, role, tenant_id, is_active) VALUES (@id, @username, @hash, @role, @tenantId, true) ON CONFLICT (id) DO UPDATE SET password_hash = @hash, tenant_id = @tenantId',
        ),
        parameters: {'id': userId, 'username': username, 'hash': passwordHash, 'role': 'superuser', 'tenantId': tenantId},
      );
    });
    JsonLogger.info('SUPERUSER_SEEDED', {'username': username});
  }
}
