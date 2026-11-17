import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

void main(List<String> args) async {
  final host = Platform.environment['SERVER_HOST'] ?? 'http://localhost:8080';

  final superUser =
      Platform.environment['SUPERUSER_USERNAME'] ??
      (throw ArgumentError('SUPERUSER_USERNAME is required'));
  final superPass =
      Platform.environment['SUPERUSER_PASSWORD'] ??
      (throw ArgumentError('SUPERUSER_PASSWORD is required'));

  print('--- 1. Logging in as Superuser ($superUser) ---');
  final loginUri = Uri.parse('$host/auth/login');
  String? superToken;

  try {
    final loginRes = await http.post(
      loginUri,
      body: jsonEncode({'username': superUser, 'password': superPass}),
      headers: {'Content-Type': 'application/json'},
    );

    if (loginRes.statusCode == 200) {
      final body = jsonDecode(loginRes.body);
      superToken = body['accessToken'];
      print('✅ Superuser Login Successful.');
    } else {
      print('❌ Superuser Login Failed: ${loginRes.body}');
      print(
        'Make sure the server is started with SUPERUSER_USERNAME/PASSWORD env vars.',
      );
      exit(1);
    }
  } catch (e) {
    print('❌ Error during login: $e');
    exit(1);
  }

  print('\n--- 2. Registering Tenant "legacy" ---');
  final createTenantUri = Uri.parse('$host/api/admin/tenants');
  final registerBody = {
    'tenantName': 'legacy',
    'adminUsername': 'admin',
    'adminPassword':
        Platform.environment['SEED_ADMIN_PASSWORD'] ??
        (throw ArgumentError('SEED_ADMIN_PASSWORD is required')),
  };
  String? tenantId;

  try {
    final regRes = await http.post(
      createTenantUri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $superToken',
      },
      body: jsonEncode(registerBody),
    );

    if (regRes.statusCode == 200) {
      final body = jsonDecode(regRes.body);
      tenantId = body['tenantId'];
      print('✅ Tenant registered: $tenantId');
    } else {
      print('❌ Registration failed: ${regRes.body}');
    }
  } catch (e) {
    print('❌ Connection error: $e');
    exit(1);
  }

  print('\n--- 3. Creating User "patrick" for tenant "legacy" ---');
  if (tenantId == null) {
    print('Skipping user creation because tenant creation failed.');
    exit(1);
  }

  final createUserUri = Uri.parse('$host/api/users');

  try {
    final createRes = await http.post(
      createUserUri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $superToken',
      },
      body: jsonEncode({
        'username': 'patrick',
        'password':
            Platform.environment['SEED_USER_PASSWORD'] ??
            (throw ArgumentError('SEED_USER_PASSWORD is required')),
        'tenantId': tenantId,
      }),
    );

    if (createRes.statusCode == 200) {
      print('✅ User "patrick" created: ${createRes.body}');
    } else {
      print('❌ Failed to create user: ${createRes.body}');
    }
  } catch (e) {
    print('❌ Error creating user: $e');
  }

  print('\n=== Setup Complete ===');
  print('Accounts created using credentials supplied in the environment.');
}
