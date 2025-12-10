import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

void main(List<String> args) async {
  final host = Platform.environment['SERVER_HOST'] ?? 'http://localhost:8080';

  final superUser = Platform.environment['SUPERUSER_USERNAME'] ?? 'superuser';
  final superPass = Platform.environment['SUPERUSER_PASSWORD'] ?? 'superuser';

  // 1. Login as Superuser
  print('--- 1. Logging in as Superuser ($superUser) ---');
  final loginUri = Uri.parse('$host/auth/login');
  String? superToken;

  try {
    final loginRes = await http.post(loginUri, body: jsonEncode({'username': superUser, 'password': superPass}), headers: {'Content-Type': 'application/json'});

    if (loginRes.statusCode == 200) {
      final body = jsonDecode(loginRes.body);
      superToken = body['accessToken'];
      print('✅ Superuser Login Successful.');
    } else {
      print('❌ Superuser Login Failed: ${loginRes.body}');
      print('Make sure the server is started with SUPERUSER_USERNAME/PASSWORD env vars.');
      exit(1);
    }
  } catch (e) {
    print('❌ Error during login: $e');
    exit(1);
  }

  // 2. Register Tenant "legacy"
  print('\n--- 2. Registering Tenant "legacy" ---');
  final createTenantUri = Uri.parse('$host/api/admin/tenants');
  final registerBody = {'tenantName': 'legacy', 'adminUsername': 'admin', 'adminPassword': 'password'};
  String? tenantId;

  try {
    final regRes = await http.post(
      createTenantUri,
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $superToken'},
      body: jsonEncode(registerBody),
    );

    if (regRes.statusCode == 200) {
      final body = jsonDecode(regRes.body);
      tenantId = body['tenantId'];
      print('✅ Tenant registered: $tenantId');
    } else {
      print('❌ Registration failed: ${regRes.body}');
      // Proceed if maybe it already exists? But API doesn't return ID if conflict easily..
      // Getting tenant ID if it exists would be nice, but for init script, we usually start fresh or fail.
    }
  } catch (e) {
    print('❌ Connection error: $e');
    exit(1);
  }

  // 3. Login as Admin to create user (OR use superuser to create user)
  // Let's use superuser to create the user directly for the tenant, exercising that superuser capability.
  print('\n--- 3. Creating User "patrick" for tenant "legacy" ---');
  if (tenantId == null) {
    print('Skipping user creation because tenant creation failed.');
    exit(1);
  }

  final createUserUri = Uri.parse('$host/api/users');

  try {
    final createRes = await http.post(
      createUserUri,
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $superToken'},
      body: jsonEncode({'username': 'patrick', 'password': 'password', 'tenantId': tenantId}),
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
  print('Superuser: $superUser / $superPass');
  print('Tenant: legacy');
  print('Admin: admin / password');
  print('User: patrick / password');
}
