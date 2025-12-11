import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http; // Add http import
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:async/async.dart';

void main() {
  Process? serverProcess;
  final random = Random();
  late String wsUrl;
  late String httpUrl;
  // final int port = 0; // Request ephemeral port
  final secret = 'test_secret_key';

  // Helper to register and get token
  Future<String> registerAndLogin(String username, {String? tenantId}) async {
    // 1. Login as Superuser (seeded by server env vars)
    final superRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': 'superuser', 'password': 'superuser'}),
      headers: {'Content-Type': 'application/json'},
    );
    if (superRes.statusCode != 200)
      throw Exception('Superuser login failed: ${superRes.body}');
    final superToken = jsonDecode(superRes.body)['accessToken'];

    // 2. Register Tenant
    // We treat the passed `tenantId` as the desired Tenant Name (which usually becomes the ID).
    final tName = tenantId ?? 'tenant_${random.nextInt(100000)}';

    // Check if it exists? The API might return existing or error.
    // Ideally we just try to create.
    final createTenantRes = await http.post(
      Uri.parse('$httpUrl/api/admin/tenants'),
      headers: {
        'Authorization': 'Bearer $superToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'tenantName': tName,
        'adminUsername': 'temp_admin_${random.nextInt(10000)}',
        'adminPassword': 'password',
      }),
    );

    // If it fails, maybe it exists? If 200, we get ID.
    // If we want to support "logging in to existing", we might need to handle 4xx.
    // But for tests creating fresh tenants, 200 is expected.
    if (createTenantRes.statusCode != 200) {
      // Fallback: If creation failed, maybe it's just a duplicate?
      // But the previous implementation threw exception.
      throw Exception('Create tenant failed: ${createTenantRes.body}');
    }
    final String effectiveTenantId = jsonDecode(
      createTenantRes.body,
    )['tenantId'];

    // 3. Create User in Tenant
    // Check if we are creating the initial admin or a regular user?
    // The test calls this with just a username.
    // If we just created the tenant, we created an admin.
    // But to be consistent with "registerAndLogin(username)", let's create a NEW user with that username.
    final createUserRes = await http.post(
      Uri.parse('$httpUrl/api/users'),
      headers: {
        'Authorization': 'Bearer $superToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'username': username,
        'password': 'password',
        'tenantId': effectiveTenantId,
      }),
    );
    if (createUserRes.statusCode != 200) {
      // If user already exists (e.g. we passed the admin username?), just proceed to login
      // But tests usually pass unique usernames.
      throw Exception('Create user failed: ${createUserRes.body}');
    }

    // 4. Login as User
    final loginRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': username, 'password': 'password'}),
      headers: {'Content-Type': 'application/json'},
    );

    if (loginRes.statusCode != 200) {
      throw Exception('Login failed: ${loginRes.body}');
    }

    return jsonDecode(loginRes.body)['accessToken'];
  }

  // Helper to add user to existing tenant (via admin token OR superuser)
  // The original test passed an ADMIN token.
  // Now only superuser can create users for ANY tenant, OR admin for OWN tenant.
  // If `adminToken` is a tenant admin, it works for that tenant.
  Future<String> registerUserInTenant(
    String adminToken,
    String username,
  ) async {
    // We need to know tenantId to create user via API if we are using superuser token,
    // OR if we are using tenant admin token, context implies it.
    // The endpoint `POST /api/users` requires `tenantId` in body if superuser,
    // or infers it from token if tenant_admin?
    // Let's check `server.dart`:
    // `final targetTenantId = (role == 'superuser') ? (body['tenantId'] as String) : tenantId;`
    // So if we use a tenant admin token, we don't strictly need to pass it, but passing it doesn't hurt if it matches.
    // However, if we don't know it here easily...
    // Let's assume `adminToken` is a valid token.

    // First, verify who is calling. Tests usually passed the result of `registerAndLogin` which returned a tenant admin token.
    // BUT now `registerAndLogin` returns a regular user token (since we create a user).
    // Wait, in `registerAndLogin` above, I create a user and return THEIR token.
    // That user currently has role 'user' (default in `api/users`?).
    // `server.dart`: `final role = body['role'] ?? 'user';`
    // And `POST /api/users` is restricted to `['tenant_admin', 'superuser']`.
    // So a regular user CANNOT create another user.
    // This breaks `registerUserInTenant` if `adminToken` is just a regular user.

    // Fix: `registerAndLogin` should probably return a tenant admin if possible, OR we rely on superuser for test setup.
    // Tests rely on `registerAndLogin` to get a token to connect to WS.

    // Strategy: Use SUPERUSER exclusively for test setup helper specific to creating users.
    // `registerUserInTenant` should act as "Provision user in tenant".

    // Login superuser again
    final superRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': 'superuser', 'password': 'superuser'}),
      headers: {'Content-Type': 'application/json'},
    );
    final superToken = jsonDecode(superRes.body)['accessToken'];

    // To create a user, we need the tenantId.
    // The previous `registerUserInTenant` didn't take tenantId, it relied on the `adminToken` context.
    // Now we need it.
    // We can extract it from the `adminToken` passed in?
    final parts = adminToken.split('.');
    final payload = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(parts[1]))),
    );
    final tId = payload['tenant_id'];

    final res = await http.post(
      Uri.parse('$httpUrl/api/users'),
      headers: {
        'Authorization': 'Bearer $superToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'username': username,
        'password': 'password',
        'tenantId': tId,
      }),
    );
    if (res.statusCode != 200)
      throw Exception('Create user failed: ${res.body}');

    // Login as new user
    final loginRes = await http.post(
      Uri.parse('$httpUrl/auth/login'),
      body: jsonEncode({'username': username, 'password': 'password'}),
      headers: {'Content-Type': 'application/json'},
    );
    return jsonDecode(loginRes.body)['accessToken'];
  }

  setUpAll(() async {
    final portCompleter = Completer<int>();

    serverProcess = await Process.start(
      'dart',
      ['bin/server.dart'],
      environment: {
        'LEGACY_GANTT_SYNC_PORT': '0',
        'JWT_SECRET': secret,
        'DB_HOST': 'localhost',
        'DB_PORT': '5432',
        'DB_USER': 'dart_user',
        'DB_PASS': 'dart_password',
        'DB_NAME': 'legacy_gantt',
        'SUPERUSER_USERNAME': 'superuser',
        'SUPERUSER_PASSWORD': 'superuser',
      },
    );

    // Listen to stdout to capture the port
    serverProcess!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          print('[Server Out] $line');
          if (!portCompleter.isCompleted) {
            try {
              // Look for JSON log with event SERVER_START
              // The line might be wrapped or have prefixes?
              // Assuming pure JSON per line or simple text search for now
              // Example: {"...":"SERVER_START", "data":{..."port":12345}}
              if (line.contains('SERVER_START')) {
                final json = jsonDecode(line);
                if (json['event'] == 'SERVER_START') {
                  final data = json['data'];
                  final actualPort = data['port'] as int;
                  portCompleter.complete(actualPort);
                }
              }
            } catch (e) {
              // Ignore parsing errors
            }
          }
        });

    serverProcess!.stderr
        .transform(utf8.decoder)
        .listen((line) => print('[Server Err] $line'));

    // Wait for the port to be captured
    try {
      final actualPort = await portCompleter.future.timeout(
        const Duration(seconds: 10),
      );
      print('Test Server started on port $actualPort');
      wsUrl = 'ws://localhost:$actualPort/ws';
      httpUrl = 'http://localhost:$actualPort';
    } catch (e) {
      throw Exception('Failed to start test server or capture port: $e');
    }
  });

  tearDownAll(() {
    serverProcess?.kill();
  });

  test('Rejects unauthorized clients', () async {
    expect(WebSocket.connect(wsUrl), throwsA(isA<WebSocketException>()));
  });

  test('Rejects invalid token', () async {
    expect(
      WebSocket.connect(
        wsUrl,
        headers: {'Authorization': 'Bearer invalid_token'},
      ),
      throwsA(isA<WebSocketException>()),
    );
  });

  // test('Server broadcasts messages to clients in same tenant', () async {
  //   // 1. Setup Tenant and Users
  //   final adminUser = 'admin_${random.nextInt(10000)}';
  //   final adminToken = await registerAndLogin(adminUser);

  //   final userBName = 'userB_${random.nextInt(10000)}';
  //   final tokenB = await registerUserInTenant(adminToken, userBName);

  //   // Connect
  //   final clientA = IOWebSocketChannel.connect(wsUrl, headers: {'Authorization': 'Bearer $adminToken'});
  //   final clientB = IOWebSocketChannel.connect(wsUrl, headers: {'Authorization': 'Bearer $tokenB'});

  //   // Extract tenantId from token A (decoded) or we can capture it during registration.
  //   // Assuming subscription channel = tenantId.
  //   // Wait, registerAndLogin creates a tenant with name `tName`.
  //   // The ID returned is `tId`.
  //   // I need `tId` to subscribe.
  //   // I will refactor helper to return Token AND TenantId.
  //   // For now, I'll fetch tenantId by decoding token or parsing register response?
  //   // Let's decode token here simply or update helper.
  //   // Refactoring helper is better but inside test for now:
  //   final parts = adminToken.split('.');
  //   final payload = jsonDecode(utf8.decode(base64.decode(base64.normalize(parts[1]))));
  //   final tenantId = payload['tenant_id'];

  //   // Try to subscribe to wrong tenant
  //   // We extracted tenantId but don't use it, just ensuring we use a DIFFERENT one
  //   clientA.sink.add(jsonEncode({'type': 'subscribe', 'channel': 'tenantB'}));

  //   clientB.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

  //   // Wait for subscriptions (db init might be slow)
  //   await Future.delayed(const Duration(seconds: 2));

  //   final message = {
  //     'type': 'UPDATE_TASK',
  //     'data': {'id': '100', 'name': 'Task 100'},
  //     'timestamp': DateTime.now().millisecondsSinceEpoch,
  //     'actorId': adminUser,
  //   };

  //   final bQueue = StreamQueue(clientB.stream);

  //   clientA.sink.add(jsonEncode(message));

  //   // Client B should receive it
  //   bool found = false;
  //   int checks = 0;
  //   while (await bQueue.hasNext && checks < 10) {
  //     checks++;
  //     final event = await bQueue.next.timeout(const Duration(seconds: 2));
  //     final decoded = jsonDecode(event as String);

  //     if (decoded['type'] == 'UPDATE_TASK' && decoded['data']['id'] == '100') {
  //       found = true;
  //       break;
  //     }
  //   }

  //   expect(found, isTrue);

  //   await clientA.sink.close();
  //   await clientB.sink.close();
  // });

  test('Isolates messages between tenants', () async {
    final t1User = 't1_${random.nextInt(10000)}';
    final tokenA = await registerAndLogin(t1User);
    final t1Id = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(tokenA.split('.')[1]))),
    )['tenant_id'];

    final t2User = 't2_${random.nextInt(10000)}';
    final tokenB = await registerAndLogin(t2User); // Different tenant
    final t2Id = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(tokenB.split('.')[1]))),
    )['tenant_id'];

    final clientA = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $tokenA'},
    );
    final clientB = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $tokenB'},
    );

    clientA.sink.add(jsonEncode({'type': 'subscribe', 'channel': t1Id}));
    clientB.sink.add(jsonEncode({'type': 'subscribe', 'channel': t2Id}));

    await Future.delayed(const Duration(milliseconds: 100));

    final message = {
      'type': 'UPDATE_TASK',
      'data': {'id': 'secret_task', 'name': 'Secret Task'},
    };

    final bQueue = StreamQueue(clientB.stream);

    // User A sends message to tenantA
    clientA.sink.add(jsonEncode(message));

    // User B should NOT receive it
    bool foundSecret = false;
    try {
      final event = await bQueue.next.timeout(
        const Duration(milliseconds: 500),
      );
      final decoded = jsonDecode(event as String);
      if (decoded['data']?['id'] == 'secret_task') {
        foundSecret = true;
      }
    } catch (e) {
      // Timeout expected
    }

    expect(foundSecret, isFalse);

    await clientA.sink.close();
    await clientB.sink.close();
  });

  test('Prevents cross-tenant subscription', () async {
    final user = 'cross_${random.nextInt(10000)}';
    final token = await registerAndLogin(user);

    final clientA = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(clientA.stream);

    // Try to subscribe to DIFFERENT channel (just random string)
    clientA.sink.add(
      jsonEncode({'type': 'subscribe', 'channel': 'some_other_tenant'}),
    );

    // Expect error message
    bool receivedError = false;
    try {
      final event = await queue.next.timeout(const Duration(seconds: 2));
      final decoded = jsonDecode(event as String);
      if (decoded['error'] == 'Forbidden channel') {
        receivedError = true;
      }
    } catch (e) {
      // nothing
    }

    expect(receivedError, isTrue);
    await clientA.sink.close();
  });

  test('New client receives history for their tenant only', () async {
    final historyUser = 'hist_${random.nextInt(10000)}';
    final token = await registerAndLogin(historyUser);
    final tenantId = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))),
    )['tenant_id'];

    final clientA = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );

    clientA.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));
    await Future.delayed(const Duration(milliseconds: 100));

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final message = {
      'type': 'UPDATE_TASK',
      'data': {
        'data': {'id': 'history_$timestamp', 'name': 'History Task'},
      },
      'timestamp': timestamp,
      'actorId': 'UserHistory',
    };

    clientA.sink.add(jsonEncode(message));
    await Future.delayed(
      const Duration(milliseconds: 1000),
    ); // Wait for DB write

    // New client (same user for simplicity, or new user in same tenant)
    // Same token/user is fine for history check
    final clientB = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final bQueue = StreamQueue(clientB.stream);

    clientB.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Should find the message in history
    bool found = false;
    try {
      while (await bQueue.hasNext) {
        final event = await bQueue.next.timeout(const Duration(seconds: 5));
        final decoded = jsonDecode(event as String);
        if (decoded['data']?['data']?['id'] == 'history_$timestamp') {
          found = true;
          break;
        }
      }
    } catch (e) {
      // Timeout
    }

    expect(found, isTrue);
    await clientB.sink.close();
    await clientA.sink.close();
  });

  test('Syncs dependencies between clients', () async {
    final depUser = 'dep_${random.nextInt(10000)}';
    final token = await registerAndLogin(depUser);
    final tenantId = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))),
    )['tenant_id'];

    final clientA = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final clientB = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );

    clientA.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));
    clientB.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    await Future.delayed(const Duration(milliseconds: 500));
    final bQueue = StreamQueue(clientB.stream);

    // 1. Insert Dependency
    final depData = {
      'predecessorTaskId': 'task1',
      'successorTaskId': 'task2',
      'type': 'finishToStart',
    };
    clientA.sink.add(
      jsonEncode({
        'type': 'INSERT_DEPENDENCY',
        'data': {'data': depData},
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    // Verify broadcast
    bool foundInsert = false;
    try {
      while (await bQueue.hasNext) {
        final rawMsg = await bQueue.next.timeout(const Duration(seconds: 2));
        final decoded = jsonDecode(rawMsg as String);
        if (decoded['type'] == 'INSERT_DEPENDENCY' &&
            decoded['data']['data']['predecessorTaskId'] == 'task1') {
          foundInsert = true;
          break;
        }
      }
    } catch (e) {
      // Timeout
    }
    expect(
      foundInsert,
      isTrue,
      reason: 'Client B should receive INSERT_DEPENDENCY',
    );

    // 2. Delete Dependency
    clientA.sink.add(
      jsonEncode({
        'type': 'DELETE_DEPENDENCY',
        'data': {'data': depData},
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    // Verify broadcast
    bool foundDelete = false;
    try {
      while (await bQueue.hasNext) {
        final event = await bQueue.next.timeout(const Duration(seconds: 2));
        final decoded = jsonDecode(event as String);
        if (decoded['type'] == 'DELETE_DEPENDENCY' &&
            decoded['data']['data']['predecessorTaskId'] == 'task1') {
          foundDelete = true;
          break;
        }
      }
    } catch (e) {
      // Timeout
    }
    expect(
      foundDelete,
      isTrue,
      reason: 'Client B should receive DELETE_DEPENDENCY',
    );

    await clientA.sink.close();
    await clientB.sink.close();

    // 3. Verify Persistence
    // Re-connect and ensure we get the CURRENT state.
    // Since we deleted the dependency, it should NOT be there?
    // Wait, I should verify persistence of INSERT first before deleting?
    // or just checking that the final state is correct.
    // Let's add another dependency and leave it there.

    final clientC = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    // final cQueue = StreamQueue(clientC.stream);
    clientC.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Insert another one
    final depData2 = {
      'predecessorTaskId': 'task3',
      'successorTaskId': 'task4',
      'type': 'startToStart',
    };
    final clientD = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    clientD.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));
    await Future.delayed(const Duration(milliseconds: 200));

    clientD.sink.add(
      jsonEncode({
        'type': 'INSERT_DEPENDENCY',
        'data': {'data': depData2},
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    await Future.delayed(const Duration(milliseconds: 500)); // Wait for DB

    // New client E should receive it in history (on subscribe)
    final clientE = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final eQueue = StreamQueue(clientE.stream);
    clientE.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    bool foundHistory = false;
    try {
      while (await eQueue.hasNext) {
        final event = await eQueue.next.timeout(const Duration(seconds: 2));
        final decoded = jsonDecode(event as String);
        if (decoded['type'] == 'INSERT_DEPENDENCY' &&
            decoded['data']['data']['predecessorTaskId'] == 'task3') {
          foundHistory = true;
          break;
        }
      }
    } catch (e) {
      // Timeout
    }
    expect(
      foundHistory,
      isTrue,
      reason: 'New client should receive persisted dependencies',
    );

    await clientC.sink.close();
    await clientD.sink.close();
    await clientE.sink.close();
  });

  test('Persists task type', () async {
    // Setup user
    final tenantId = 'type_test_tenant_${random.nextInt(10000)}';
    final username = 'user_type_test_${random.nextInt(10000)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    // 1. Connect Client 1
    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = jsonDecode(element as String);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // 2. Send Update with type
    final updateMsg = {
      'type': 'UPDATE_TASK',
      'data': {
        'data': {
          'id': 'task-type-test',
          'name': 'Milestone Task',
          'type': 'milestone',
        },
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'actorId': 'user_type_test',
    };
    client1.sink.add(jsonEncode(updateMsg));
    await Future.delayed(const Duration(milliseconds: 500));
    await client1.sink.close();

    // 3. New client connects, should receive task with type
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(client2.stream);
    client2.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Look for the task in history
    bool found = false;
    try {
      while (await queue.hasNext) {
        final event = await queue.next.timeout(const Duration(seconds: 2));
        final msg = jsonDecode(event as String);
        if (msg['type'] == 'UPDATE_TASK' &&
            msg['data']['data']['id'] == 'task-type-test') {
          // Check for 'gantt_type' or 'ganttType' or 'type' mapped correctly.
          // Since we query DB columns, it will likely come back as 'gantt_type' if we used SELECT *
          // But our current implementation sends raw JSON from DB. `postgres` returns keys as column names.
          final data = msg['data']['data'];
          if (data['gantt_type'] == 'milestone') {
            found = true;
            break;
          }
        }
      }
    } catch (_) {
      // End of stream or timeout
    }
    expect(
      found,
      isTrue,
      reason: 'Task with gantt_type should be persisted and sent to new client',
    );
    await client2.sink.close();
  });

  test('Persists task with camelCase keys (field mapping)', () async {
    final tenantId = 'mapping_test_tenant_${random.nextInt(10000)}';
    final username = 'user_mapping_test_${random.nextInt(10000)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = jsonDecode(element as String);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // Send Update with camelCase keys (parentId, startDate)
    final updateMsg = {
      'type': 'UPDATE_TASK',
      'data': {
        'data': {
          'id': 'task-mapping-test',
          'name': 'Mapping Task',
          'parentId': 'parent-task-1',
          'startDate': 1000,
          'endDate': 2000,
        },
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'actorId': 'user_mapping_test',
    };
    client1.sink.add(jsonEncode(updateMsg));
    await Future.delayed(const Duration(milliseconds: 500));
    await client1.sink.close();

    // Verify persistence via new connection
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(client2.stream);
    client2.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    bool found = false;
    try {
      while (await queue.hasNext) {
        final event = await queue.next.timeout(const Duration(seconds: 2));
        final msg = jsonDecode(event as String);
        if (msg['type'] == 'UPDATE_TASK' &&
            msg['data']['data']['id'] == 'task-mapping-test') {
          // Check that fields were saved (server returns them as is or mapped - likely returns what fits schema)
          // Actually, our current logic broadcasts the ORIGINAL payload immediately, merging later?
          // No, subscribe sends from DB. So we expect `parent_id` from DB or snake_case keys.
          // Wait, the `subscribe` handler in server sends `SELECT *`. So keys will be snake_case!
          // BUT, `row_to_json` or simple query returns DB columns.
          // Let's check what came back.
          final data = msg['data']['data'];
          if (data['parent_id'] == 'parent-task-1' ||
              data['parentId'] == 'parent-task-1') {
            found = true;
          }
          break;
        }
      }
    } catch (_) {}
    expect(found, isTrue, reason: 'Task with mapped keys should be persisted');
    await client2.sink.close();
  });

  test('Supports INSERT_RESOURCE with root gantt_type', () async {
    final tenantId = 'resource_test_tenant_${random.nextInt(10000)}';
    final username = 'user_resource_test_${random.nextInt(10000)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = jsonDecode(element as String);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // Send INSERT_RESOURCE with gantt_type at root
    client1.sink.add(
      jsonEncode({
        'type': 'INSERT_RESOURCE', // Operation Type
        'data': {
          'gantt_type': 'human', // Root property
          'data': {'id': 'resource-test-1', 'name': 'Test Resource'},
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_resource_test_${random.nextInt(10000)}@$tenantId',
      }),
    );
    await Future.delayed(const Duration(milliseconds: 500));
    await client1.sink.close();

    // Verify persistence
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(client2.stream);
    client2.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    bool found = false;
    try {
      while (await queue.hasNext) {
        final event = await queue.next.timeout(const Duration(seconds: 2));
        final msg = jsonDecode(event as String);
        // Expect INSERT_RESOURCE or UPDATE_TASK depending on what we sent. Server reflects checks.
        if ((msg['type'] == 'UPDATE_TASK' ||
                msg['type'] == 'INSERT_RESOURCE') &&
            msg['data']['data']['id'] == 'resource-test-1') {
          final data = msg['data']['data'];
          if (data['gantt_type'] == 'human') {
            found = true;
          }
          break;
        }
      }
    } catch (_) {}
    expect(
      found,
      isTrue,
      reason: 'INSERT_RESOURCE with root gantt_type should be persisted',
    );
    await client2.sink.close();
  });

  test('Supports nested data payload (unwrapping)', () async {
    final tenantId = 'nested_test_tenant_${random.nextInt(10000)}';
    final username = 'user_nested_test_${random.nextInt(10000)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = jsonDecode(element as String);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // Send Nested Payload: { data: { gantt_type: ..., data: { id: ... } } }
    client1.sink.add(
      jsonEncode({
        'type': 'INSERT_RESOURCE',
        'data': {
          'gantt_type': 'tool',
          'data': {'id': 'nested-resource-1', 'name': 'Nested Resource'},
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_nested_test_${random.nextInt(10000)}@$tenantId',
      }),
    );
    await Future.delayed(const Duration(milliseconds: 500));
    await client1.sink.close();

    // Verify persistence
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(client2.stream);
    client2.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    bool found = false;
    try {
      while (await queue.hasNext) {
        final event = await queue.next.timeout(const Duration(seconds: 2));
        final msg = jsonDecode(event as String);
        if ((msg['type'] == 'UPDATE_TASK' ||
                msg['type'] == 'INSERT_RESOURCE') &&
            msg['data']['data']['id'] == 'nested-resource-1') {
          final data = msg['data']['data'];
          if (data['gantt_type'] == 'tool' &&
              data['name'] == 'Nested Resource') {
            found = true;
          }
          break;
        }
      }
    } catch (_) {}
    expect(
      found,
      isTrue,
      reason: 'Nested payload should be unwrapped and persisted',
    );
    await client2.sink.close();
  });

  test('Persists dependency_type correctly', () async {
    final tenantId = 'dep_type_test_${random.nextInt(10000)}';
    final username = 'user_dep_type_${random.nextInt(10000)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = jsonDecode(element as String);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // Send INSERT_DEPENDENCY with dependencyType key
    client1.sink.add(
      jsonEncode({
        'type': 'INSERT_DEPENDENCY',
        'data': {
          'data': {
            'predecessorTaskId': 'task-a',
            'successorTaskId': 'task-b',
            'dependency_type': 'startToStart',
          },
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_dep_type_${random.nextInt(10000)}@$tenantId',
      }),
    );
    await Future.delayed(const Duration(milliseconds: 500));
    await client1.sink.close();

    // Verify persistence via new connection
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(client2.stream);
    client2.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    bool found = false;
    try {
      while (await queue.hasNext) {
        final event = await queue.next.timeout(const Duration(seconds: 2));
        final msg = jsonDecode(event as String);
        if (msg['type'] == 'INSERT_DEPENDENCY') {
          final data = msg['data']['data'];
          if (data['predecessorTaskId'] == 'task-a' &&
              data['successorTaskId'] == 'task-b' &&
              (data['dependency_type'] == 'startToStart' ||
                  data['type'] == 'startToStart')) {
            found = true;
            break;
          }
        }
      }
    } catch (_) {}
    expect(
      found,
      isTrue,
      reason: 'Dependency with dependencyType should be persisted',
    );
    await client2.sink.close();
  });

  test('Handles RESET_DATA operation', () async {
    final tenantId = 'reset_test_tenant_${random.nextInt(10000)}';
    final username = 'user_reset_${random.nextInt(10000)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    // 1. Setup Data (Task + Dependency)
    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));
    await client1.stream.firstWhere(
      (e) => jsonDecode(e as String)['type'] == 'SUBSCRIBE_SUCCESS',
    );

    // Create Task
    client1.sink.add(
      jsonEncode({
        'type': 'INSERT_TASK',
        'data': {
          'data': {'id': 'task-reset-1', 'name': 'To Be Deleted'},
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_reset',
      }),
    );
    await Future.delayed(const Duration(milliseconds: 200));

    // Create Dependency (Requires 2 tasks logically, but DB doesn't enforce FKs in this CRDT setup yet, just checks pred/succ IDs usually)
    // Let's just insert one dependency
    client1.sink.add(
      jsonEncode({
        'type': 'INSERT_DEPENDENCY',
        'data': {
          'data': {
            'predecessorTaskId': 'task-reset-1',
            'successorTaskId': 'task-reset-2',
          },
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'dep_${random.nextInt(10000)}',
      }),
    );
    await Future.delayed(const Duration(milliseconds: 200));

    // 2. Send RESET_DATA
    client1.sink.add(
      jsonEncode({
        'type': 'RESET_DATA',
        'data': {},
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_reset',
      }),
    );
    await Future.delayed(const Duration(milliseconds: 200));

    // 2. Setup Client 2 (Observer - Different User)
    final observerUsername = 'user_reset_obs_${random.nextInt(10000)}';
    final observerToken = await registerUserInTenant(token, observerUsername);
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $observerToken'},
    );
    final queue2 = StreamQueue(client2.stream);
    client2.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));
    await queue2.next; // SUBSCRIBE_SUCCESS

    // 3. Send RESET_DATA from Client 1
    // We also want to verify Client 1 DOES NOT receive the broadcast
    final queue1 = StreamQueue(client1.stream);

    client1.sink.add(
      jsonEncode({
        'type': 'RESET_DATA',
        'data': {},
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_reset',
      }),
    );

    // 4. Verify Client 2 receives RESET_DATA
    bool resetReceived2 = false;
    try {
      while (await queue2.hasNext) {
        final raw = await queue2.next.timeout(const Duration(seconds: 2));
        final msg = jsonDecode(raw as String);
        if (msg['type'] == 'RESET_DATA') {
          resetReceived2 = true;
          break;
        }
      }
    } catch (_) {}
    expect(
      resetReceived2,
      isTrue,
      reason: 'Client 2 should receive RESET_DATA broadcast',
    );

    // 5. Verify Client 1 DOES NOT receive RESET_DATA
    bool resetReceived1 = false;
    try {
      // Use timeout to verify absence of message
      final raw = await queue1.next.timeout(const Duration(seconds: 2));
      final msg = jsonDecode(raw as String);
      if (msg['type'] == 'RESET_DATA') {
        resetReceived1 = true;
      }
    } catch (e) {
      // Timeout expected if no message received
    }
    expect(
      resetReceived1,
      isFalse,
      reason: 'Client 1 should NOT receive self-broadcast',
    );

    await client1.sink.close();

    // 5. Verify Empty State (Optional, already checked, but good double check)
    // Reconnect to check state is empty
    final client3 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue3 = StreamQueue(client3.stream);
    client3.sink.add(jsonEncode({'type': 'subscribe', 'channel': tenantId}));

    bool hasData = false;
    try {
      while (true) {
        final event = await queue3.next.timeout(const Duration(seconds: 1));
        final msg = jsonDecode(event as String);
        if (msg['type'] == 'UPDATE_TASK' ||
            msg['type'] == 'INSERT_DEPENDENCY') {
          hasData = true;
          break;
        }
      }
    } catch (_) {
      // Timeout means no (more) data received
    }
    expect(
      hasData,
      isFalse,
      reason: 'Tenant data should be empty after RESET_DATA',
    );

    await client2.sink.close();
    await client3.sink.close();
  });
}
