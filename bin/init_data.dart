import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

void main(List<String> args) async {
  final host = Platform.environment['SERVER_HOST'] ?? 'http://localhost:8080';

  // 1. Register Tenant and Admin
  print('--- 1. Registering Tenant "legacy" and Admin "admin" ---');
  final registerUri = Uri.parse('$host/auth/register');
  final registerBody = {
    'tenantName': 'legacy',
    'adminUsername': 'admin',
    'adminPassword': 'password', // Default password
  };

  try {
    final regRes = await http.post(registerUri, body: jsonEncode(registerBody), headers: {'Content-Type': 'application/json'});

    if (regRes.statusCode == 200) {
      print('✅ Tenant registered: ${regRes.body}');
    } else {
      print('❌ Registration failed (might already exist): ${regRes.body}');
      // Proceeding anyway as it might just be the tenant exists, but we can still try to login
    }
  } catch (e) {
    print('❌ Connection error: $e');
    exit(1);
  }

  // 2. Login as Admin
  print('\n--- 2. Logging in as Admin ---');
  final loginUri = Uri.parse('$host/auth/login');
  String? adminToken;

  try {
    final loginRes = await http.post(loginUri, body: jsonEncode({'username': 'admin', 'password': 'password'}), headers: {'Content-Type': 'application/json'});

    if (loginRes.statusCode == 200) {
      final body = jsonDecode(loginRes.body);
      adminToken = body['accessToken'];
      print('✅ Admin Login Successful.');
      // print('Token: $adminToken'); // Verify silently
    } else {
      print('❌ Admin Login Failed: ${loginRes.body}');
      exit(1);
    }
  } catch (e) {
    print('❌ Error during login: $e');
    exit(1);
  }

  // 3. Create User 'patrick'
  print('\n--- 3. Creating User "patrick" ---');
  final createUserUri = Uri.parse('$host/api/users');

  try {
    final createRes = await http.post(
      createUserUri,
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $adminToken'},
      body: jsonEncode({
        'username': 'patrick',
        'password': 'password', // Default password
      }),
    );

    if (createRes.statusCode == 200) {
      print('✅ User "patrick" created: ${createRes.body}');
    } else {
      print('❌ Failed to create user (might already exist): ${createRes.body}');
    }
  } catch (e) {
    print('❌ Error creating user: $e');
  }

  print('\n=== Setup Complete ===');
  print('Tenant: legacy');
  print('Admin: admin / password');
  print('User: patrick / password');
}
