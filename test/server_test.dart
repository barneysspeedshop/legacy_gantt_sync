import 'support/wire_protocol.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http; // Add http import
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:async/async.dart';

Future<List<Map<String, dynamic>>> readSnapshot(
  StreamQueue<dynamic> queue,
) async {
  int? expectedCount;
  final operations = <Map<String, dynamic>>[];
  while (true) {
    final message = decodeMessage(
      await queue.next.timeout(const Duration(seconds: 5)),
    );
    if (message['type'] == 'SYNC_METADATA') {
      expectedCount = message['data']['totalOperations'] as int;
      if (expectedCount == 0) {
        return operations;
      }
    }
    if (message['type'] == 'BATCH_UPDATE') {
      operations.addAll(
        List<Map<String, dynamic>>.from(message['data']['operations'] as List),
      );
      if (expectedCount != null && operations.length >= expectedCount) {
        return operations;
      }
    }
    if (message['type'] == 'ERROR') {
      fail('Snapshot failed: ${message['error']}');
    }
  }
}

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
    if (superRes.statusCode != 200) {
      throw Exception('Superuser login failed: ${superRes.body}');
    }
    final superToken = jsonDecode(superRes.body)['accessToken'];

    // 2. Register Tenant
    // We treat the passed `tenantId` as the desired Tenant Name (which usually becomes the ID).
    final tName = tenantId ?? 'tenant_${random.nextInt(1 << 32)}';

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
        'adminUsername': 'temp_admin_${random.nextInt(1 << 32)}',
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
    if (res.statusCode != 200) {
      throw Exception('Create user failed: ${res.body}');
    }

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
        'DB_PORT': Platform.environment['TEST_DB_PORT']!,
        'DB_USER': 'dart_user',
        'DB_PASS': Platform.environment['TEST_DB_PASS']!,
        'DB_NAME': 'legacy_gantt',
        'REDIS_HOST': '127.0.0.1',
        'REDIS_PORT': Platform.environment['TEST_REDIS_PORT']!,
        'DB_SSL_MODE': 'disable',
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

  // test('Server broadcasts messages to clients in same tenant', () async {
  //   // 1. Setup Tenant and Users
  //   final adminUser = 'admin_${random.nextInt(1 << 32)}';
  //   final adminToken = await registerAndLogin(adminUser);

  //   final userBName = 'userB_${random.nextInt(1 << 32)}';
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
  //   clientA.sink.add(encodeMessage({'type': 'subscribe', 'channel': 'tenantB'}));

  //   clientB.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

  //   // Wait for subscriptions (db init might be slow)
  //   await Future.delayed(const Duration(seconds: 2));

  //   final message = {
  //     'type': 'UPDATE_TASK',
  //     'data': {'id': '100', 'name': 'Task 100'},
  //     'timestamp': DateTime.now().millisecondsSinceEpoch,
  //     'actorId': adminUser,
  //   };

  //   final bQueue = StreamQueue(clientB.stream);

  //   clientA.sink.add(encodeMessage(message));

  //   // Client B should receive it
  //   bool found = false;
  //   int checks = 0;
  //   while (await bQueue.hasNext && checks < 10) {
  //     checks++;
  //     final event = await bQueue.next.timeout(const Duration(seconds: 2));
  //     final decoded = decodeMessage(event);

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
    final t1User = 't1_${random.nextInt(1 << 32)}';
    final tokenA = await registerAndLogin(t1User);
    final t1Id = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(tokenA.split('.')[1]))),
    )['tenant_id'];

    final t2User = 't2_${random.nextInt(1 << 32)}';
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

    clientA.sink.add(encodeMessage({'type': 'subscribe', 'channel': t1Id}));
    clientB.sink.add(encodeMessage({'type': 'subscribe', 'channel': t2Id}));

    await Future.delayed(const Duration(milliseconds: 100));

    final message = {
      'type': 'UPDATE_TASK',
      'data': {'id': 'secret_task', 'name': 'Secret Task'},
    };

    final bQueue = StreamQueue(clientB.stream);

    // User A sends message to tenantA
    clientA.sink.add(encodeMessage(message));

    // User B should NOT receive it
    bool foundSecret = false;
    try {
      final event = await bQueue.next.timeout(
        const Duration(milliseconds: 500),
      );
      final decoded = decodeMessage(event);
      if (decoded['data']?['id'] == 'secret_task') {
        foundSecret = true;
      }
    } catch (e) {
      // Timeout expected
    }

    expect(foundSecret, isFalse);

    await clientA.sink.close();
    await bQueue.cancel(immediate: true);
    await clientB.sink.close();
  });

  test('Prevents cross-tenant subscription', () async {
    final user = 'cross_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(user);

    final clientA = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(clientA.stream);

    // Try to subscribe to DIFFERENT channel (just random string)
    clientA.sink.add(
      encodeMessage({'type': 'subscribe', 'channel': 'some_other_tenant'}),
    );

    // Expect error message
    bool receivedError = false;
    try {
      while (true) {
        final event = await queue.next.timeout(const Duration(seconds: 2));
        final decoded = decodeMessage(event);
        if (decoded['error'] == 'Forbidden channel') {
          receivedError = true;
          break;
        }
      }
    } catch (e) {
      // nothing
    }

    expect(receivedError, isTrue);
    await queue.cancel(immediate: true);
    await clientA.sink.close();
  });

  test('New client receives history for their tenant only', () async {
    final historyUser = 'hist_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(historyUser);
    final tenantId = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(token.split('.')[1]))),
    )['tenant_id'];

    final clientA = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );

    clientA.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));
    await Future.delayed(const Duration(milliseconds: 100));

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final message = {
      'type': 'UPDATE_TASK',
      'data': {'id': 'history_$timestamp', 'name': 'History Task'},
      'timestamp': timestamp,
      'actorId': 'UserHistory',
    };

    clientA.sink.add(encodeMessage(message));
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

    clientB.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    final snapshot = await readSnapshot(bQueue);
    expect(
      snapshot,
      contains(
        predicate<Map<String, dynamic>>(
          (operation) =>
              operation['type'] == 'UPDATE_TASK' &&
              operation['data']['id'] == 'history_$timestamp' &&
              operation['data']['name'] == 'History Task',
        ),
      ),
    );
    await bQueue.cancel(immediate: true);
    await clientB.sink.close();
    await clientA.sink.close();
  });

  test('Syncs dependencies between clients', () async {
    final depUser = 'dep_${random.nextInt(1 << 32)}';
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

    clientA.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));
    clientB.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    await Future.delayed(const Duration(milliseconds: 500));
    final bQueue = StreamQueue(clientB.stream);

    // 1. Insert Dependency
    final depData = {
      'predecessorTaskId': 'task1',
      'successorTaskId': 'task2',
      'type': 'finishToStart',
    };
    clientA.sink.add(
      encodeMessage({
        'type': 'INSERT_DEPENDENCY',
        'data': depData,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    // Verify broadcast
    bool foundInsert = false;
    try {
      while (true) {
        final rawMsg = await bQueue.next.timeout(const Duration(seconds: 2));
        final decoded = decodeMessage(rawMsg);
        if (decoded['type'] == 'INSERT_DEPENDENCY' &&
            decoded['data']['predecessorTaskId'] == 'task1') {
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
      encodeMessage({
        'type': 'DELETE_DEPENDENCY',
        'data': depData,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    // Verify broadcast
    bool foundDelete = false;
    try {
      while (true) {
        final event = await bQueue.next.timeout(const Duration(seconds: 2));
        final decoded = decodeMessage(event);
        if (decoded['type'] == 'DELETE_DEPENDENCY' &&
            decoded['data']['predecessorTaskId'] == 'task1') {
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
    await bQueue.cancel(immediate: true);
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
    clientC.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

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
    clientD.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));
    await Future.delayed(const Duration(milliseconds: 200));

    clientD.sink.add(
      encodeMessage({
        'type': 'INSERT_DEPENDENCY',
        'data': depData2,
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
    clientE.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    final snapshot = await readSnapshot(eQueue);
    expect(
      snapshot,
      contains(
        predicate<Map<String, dynamic>>(
          (operation) =>
              operation['type'] == 'UPDATE_DEPENDENCY' &&
              operation['data']['predecessorTaskId'] == 'task3' &&
              operation['data']['successorTaskId'] == 'task4' &&
              operation['data']['type'] == 'startToStart',
        ),
      ),
    );

    await clientC.sink.close();
    await clientD.sink.close();
    await eQueue.cancel(immediate: true);
    await clientE.sink.close();
  });

  test('Persists task type', () async {
    // Setup user
    final tenantId = 'type_test_tenant_${random.nextInt(1 << 32)}';
    final username = 'user_type_test_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    // 1. Connect Client 1
    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = decodeMessage(element);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // 2. Send Update with type
    final updateMsg = {
      'type': 'UPDATE_TASK',
      'data': {
        'id': 'task-type-test',
        'name': 'Milestone Task',
        'isMilestone': true,
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'actorId': 'user_type_test',
    };
    client1.sink.add(encodeMessage(updateMsg));
    await Future.delayed(const Duration(milliseconds: 500));
    await client1.sink.close();

    // 3. New client connects, should receive task with type
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue = StreamQueue(client2.stream);
    client2.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    final snapshot = await readSnapshot(queue);
    final task = snapshot.singleWhere(
      (operation) =>
          operation['type'] == 'UPDATE_TASK' &&
          operation['data']['id'] == 'task-type-test',
    );
    expect(task['data']['isMilestone'], isTrue);
    expect(task['data']['name'], 'Milestone Task');
    await queue.cancel(immediate: true);
    await client2.sink.close();
  });

  for (final batch in [false, true]) {
    test(
      'Persists canonical task fields through binary snapshots (batch: $batch)',
      () async {
        final tenantId = 'mapping_test_tenant_${random.nextInt(1 << 32)}';
        final username = 'user_mapping_test_${random.nextInt(1 << 32)}';
        final token = await registerAndLogin(username, tenantId: tenantId);

        final client1 = IOWebSocketChannel.connect(
          wsUrl,
          headers: {'Authorization': 'Bearer $token'},
        );
        client1.sink.add(
          encodeMessage({'type': 'subscribe', 'channel': tenantId}),
        );

        // Wait for subscribe success
        await client1.stream.firstWhere((element) {
          final msg = decodeMessage(element);
          return msg['type'] == 'SUBSCRIBE_SUCCESS';
        });

        // Send Update with camelCase keys (parentId, startDate)
        final updateMsg = {
          'type': 'UPDATE_TASK',
          'data': {
            'id': 'task-mapping-test',
            'name': 'Mapping Task',
            'parentId': 'parent-task-1',
            'startDate': 1000,
            'endDate': 2000,
            'resourceId': 'resource-1',
            'rowId': 'row-1',
            'completion': 0.5,
            'notes': 'Roundtrip notes',
            'metadataJson': jsonEncode({
              'stackIndex': 3,
              'load': 2.0,
              'isAutoScheduled': false,
              'originalId': 'imported-1',
              'isTimeRangeHighlight': true,
              'isOverlapIndicator': true,
              'externalReference': {'system': 'example', 'id': 'custom-42'},
              'color': '#80010203',
              'textColor': '#ff112233',
              'usesWorkCalendar': true,
              'propagatesMoveToChildren': false,
              'resizePolicy': 'elastic',
              'baselineStart': '1970-01-01T00:00:00.500Z',
              'baselineEnd': '1970-01-01T00:00:02.500Z',
            }),
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'actorId': 'user_mapping_test',
        };
        client1.sink.add(
          encodeMessage(
            batch
                ? {
                    'type': 'BATCH_UPDATE',
                    'data': <String, dynamic>{
                      'operations': [
                        {...updateMsg, 'type': 'INSERT_TASK'},
                      ],
                    },
                    'timestamp': DateTime.now().millisecondsSinceEpoch,
                    'actorId': 'user_mapping_test',
                  }
                : updateMsg,
          ),
        );
        await Future.delayed(const Duration(milliseconds: 500));
        await client1.sink.close();

        // Verify persistence via new connection
        final client2 = IOWebSocketChannel.connect(
          wsUrl,
          headers: {'Authorization': 'Bearer $token'},
        );
        final queue = StreamQueue(client2.stream);
        client2.sink.add(
          encodeMessage({'type': 'subscribe', 'channel': tenantId}),
        );

        final snapshot = await readSnapshot(queue);
        final task = snapshot.singleWhere(
          (operation) =>
              operation['type'] == 'UPDATE_TASK' &&
              operation['data']['id'] == 'task-mapping-test',
        );
        expect(task['data']['parentId'], 'parent-task-1');
        expect(task['data']['resourceId'], 'resource-1');
        expect(task['data']['rowId'], 'row-1');
        expect(task['data']['completion'], 0.5);
        expect(task['data']['notes'], 'Roundtrip notes');
        expect(task['data']['stackIndex'], 3);
        expect(task['data']['load'], 2.0);
        expect(task['data']['isAutoScheduled'], isFalse);
        expect(task['data']['originalId'], 'imported-1');
        expect(task['data']['isTimeRangeHighlight'], isTrue);
        expect(task['data']['isOverlapIndicator'], isTrue);
        expect(task['data']['externalReference'], {
          'system': 'example',
          'id': 'custom-42',
        });
        expect(task['data']['color'], '80010203');
        expect(task['data']['textColor'], 'ff112233');
        expect(task['data']['usesWorkCalendar'], isTrue);
        expect(task['data']['propagatesMoveToChildren'], isFalse);
        expect(task['data']['resizePolicy'], 'elastic');
        expect(task['data']['baselineStart'], '1970-01-01T00:00:00.500Z');
        expect(task['data']['baselineEnd'], '1970-01-01T00:00:02.500Z');
        expect(
          task['data']['start'],
          DateTime.fromMillisecondsSinceEpoch(
            1000,
            isUtc: true,
          ).toIso8601String(),
        );
        expect(
          task['data']['end'],
          DateTime.fromMillisecondsSinceEpoch(
            2000,
            isUtc: true,
          ).toIso8601String(),
        );
        await queue.cancel(immediate: true);
        await client2.sink.close();
      },
    );
  }

  test('Persists a typed resource from a binary operation', () async {
    final tenantId = 'resource_test_tenant_${random.nextInt(1 << 32)}';
    final username = 'user_resource_test_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = decodeMessage(element);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // Send INSERT_RESOURCE with gantt_type at root
    client1.sink.add(
      encodeMessage({
        'type': 'INSERT_RESOURCE', // Operation Type
        'data': {
          'type': 'human',
          'id': 'resource-test-1',
          'name': 'Test Resource',
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_resource_test_${random.nextInt(1 << 32)}@$tenantId',
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
    client2.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    final snapshot = await readSnapshot(queue);
    final resource = snapshot.singleWhere(
      (operation) =>
          operation['type'] == 'UPDATE_RESOURCE' &&
          operation['data']['id'] == 'resource-test-1',
    );
    expect(resource['data']['type'], 'human');
    expect(resource['data']['name'], 'Test Resource');
    await queue.cancel(immediate: true);
    await client2.sink.close();
  });

  test('Persists resource parent from a binary operation', () async {
    final tenantId = 'nested_test_tenant_${random.nextInt(1 << 32)}';
    final username = 'user_nested_test_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = decodeMessage(element);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // Typed resource fields survive persistence and a fresh subscription.
    client1.sink.add(
      encodeMessage({
        'type': 'INSERT_RESOURCE',
        'data': {
          'type': 'tool',
          'id': 'nested-resource-1',
          'name': 'Nested Resource',
          'parentId': 'tools-root',
          'metadataJson': jsonEncode({
            'isExpanded': false,
            'category': 'equipment',
            'custom': {'rate': 3},
          }),
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_nested_test_${random.nextInt(1 << 32)}@$tenantId',
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
    client2.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    final snapshot = await readSnapshot(queue);
    final resource = snapshot.singleWhere(
      (operation) =>
          operation['type'] == 'UPDATE_RESOURCE' &&
          operation['data']['id'] == 'nested-resource-1',
    );
    expect(resource['data']['type'], 'tool');
    expect(resource['data']['name'], 'Nested Resource');
    expect(resource['data']['parentId'], 'tools-root');
    expect(resource['data']['isExpanded'], isFalse);
    expect(resource['data']['category'], 'equipment');
    expect(resource['data']['custom'], {'rate': 3});
    await queue.cancel(immediate: true);
    await client2.sink.close();
  });

  test('Persists dependency type in the binary snapshot', () async {
    final tenantId = 'dep_type_test_${random.nextInt(1 << 32)}';
    final username = 'user_dep_type_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    client1.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    // Wait for subscribe success
    await client1.stream.firstWhere((element) {
      final msg = decodeMessage(element);
      return msg['type'] == 'SUBSCRIBE_SUCCESS';
    });

    // Send INSERT_DEPENDENCY with dependencyType key
    client1.sink.add(
      encodeMessage({
        'type': 'INSERT_DEPENDENCY',
        'data': {
          'predecessorTaskId': 'task-a',
          'successorTaskId': 'task-b',
          'type': 'startToStart',
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_dep_type_${random.nextInt(1 << 32)}@$tenantId',
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
    client2.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    final snapshot = await readSnapshot(queue);
    final dependency = snapshot.singleWhere(
      (operation) =>
          operation['type'] == 'UPDATE_DEPENDENCY' &&
          operation['data']['predecessorTaskId'] == 'task-a',
    );
    expect(dependency['data']['successorTaskId'], 'task-b');
    expect(dependency['data']['type'], 'startToStart');
    await queue.cancel(immediate: true);
    await client2.sink.close();
  });

  test('Handles RESET_DATA operation', () async {
    final tenantId = 'reset_test_tenant_${random.nextInt(1 << 32)}';
    final username = 'user_reset_${random.nextInt(1 << 32)}';
    final token = await registerAndLogin(username, tenantId: tenantId);

    // 1. Setup Data (Task + Dependency)
    final client1 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue1 = StreamQueue(client1.stream);
    client1.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));
    await readSnapshot(queue1);

    // Create Task
    client1.sink.add(
      encodeMessage({
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
      encodeMessage({
        'type': 'INSERT_DEPENDENCY',
        'data': {
          'predecessorTaskId': 'task-reset-1',
          'successorTaskId': 'task-reset-2',
          'type': 'finishToStart',
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'dep_${random.nextInt(1 << 32)}',
      }),
    );
    await Future.delayed(const Duration(milliseconds: 200));

    // 2. Setup Client 2 (Observer - Different User)
    final observerUsername = 'user_reset_obs_${random.nextInt(1 << 32)}';
    final observerToken = await registerUserInTenant(token, observerUsername);
    final client2 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $observerToken'},
    );
    final queue2 = StreamQueue(client2.stream);
    client2.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));
    final beforeReset = await readSnapshot(queue2);
    expect(
      beforeReset.map((operation) => operation['type']),
      unorderedEquals(['UPDATE_TASK', 'UPDATE_DEPENDENCY']),
    );

    // 3. Send RESET_DATA from Client 1
    // We also want to verify Client 1 DOES NOT receive the broadcast
    client1.sink.add(
      encodeMessage({
        'type': 'RESET_DATA',
        'data': <String, dynamic>{},
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'actorId': 'user_reset',
      }),
    );

    // 4. Verify Client 2 receives RESET_DATA
    bool resetReceived2 = false;
    try {
      while (true) {
        final raw = await queue2.next.timeout(const Duration(seconds: 2));
        final msg = decodeMessage(raw);
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
      while (true) {
        final raw = await queue1.next.timeout(
          const Duration(milliseconds: 300),
        );
        if (decodeMessage(raw)['type'] == 'RESET_DATA') {
          resetReceived1 = true;
          break;
        }
      }
    } catch (e) {
      // Timeout expected if no message received
    }
    expect(
      resetReceived1,
      isFalse,
      reason: 'Client 1 should NOT receive self-broadcast',
    );

    await queue1.cancel(immediate: true);
    await client1.sink.close();

    // 5. Verify Empty State (Optional, already checked, but good double check)
    // Reconnect to check state is empty
    final client3 = IOWebSocketChannel.connect(
      wsUrl,
      headers: {'Authorization': 'Bearer $token'},
    );
    final queue3 = StreamQueue(client3.stream);
    client3.sink.add(encodeMessage({'type': 'subscribe', 'channel': tenantId}));

    final snapshot = await readSnapshot(queue3);
    expect(
      snapshot.map((operation) => operation['type']),
      unorderedEquals(['DELETE_TASK', 'DELETE_DEPENDENCY']),
    );
    expect(
      snapshot.singleWhere(
        (operation) => operation['type'] == 'DELETE_TASK',
      )['data']['id'],
      'task-reset-1',
    );
    final deletedDependency = snapshot.singleWhere(
      (operation) => operation['type'] == 'DELETE_DEPENDENCY',
    );
    expect(deletedDependency['data']['predecessorTaskId'], 'task-reset-1');
    expect(deletedDependency['data']['successorTaskId'], 'task-reset-2');

    await queue2.cancel(immediate: true);
    await client2.sink.close();
    await queue3.cancel(immediate: true);
    await client3.sink.close();
  });
}
