import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart';

Future<void> main() async {
  print('Connecting to DB...');
  final crdt = await PostgresCrdt.open(
    'legacy_gantt',
    host: 'localhost',
    port: 5432,
    username: 'dart_user',
    password: 'dart_password',
    sslMode: SslMode.disable,
  );

  print('Creating schema...');
  final tenantId = 'test_tenant_${DateTime.now().millisecondsSinceEpoch}';
  await crdt.execute('CREATE SCHEMA IF NOT EXISTS "$tenantId"');
  await crdt.execute('''
    CREATE TABLE IF NOT EXISTS "$tenantId".dependencies (
      predecessor_task_id TEXT NOT NULL,
      successor_task_id TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'finishToStart',
      hlc TEXT NOT NULL DEFAULT '',
      node_id TEXT NOT NULL DEFAULT '',
      modified TEXT NOT NULL DEFAULT '',
      is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
      PRIMARY KEY (predecessor_task_id, successor_task_id)
    )
  ''');

  print('Testing TypedValue...');
  try {
    await crdt.execute('INSERT INTO "$tenantId".dependencies (predecessor_task_id, successor_task_id, type) VALUES (\$1, \$2, \$3)', [
      TypedValue(Type.text, 't1'),
      TypedValue(Type.text, 't2'),
      TypedValue(Type.text, 'finishToStart'),
    ]);
    print('SUCCESS: TypedValue worked!');
  } catch (e) {
    print('FAILURE: TypedValue failed: $e');
  }

  print('Testing ? syntax...');
  try {
    await crdt.execute('INSERT INTO "$tenantId".dependencies (predecessor_task_id, successor_task_id, type) VALUES (?, ?, ?)', ['t3', 't4', 'finishToStart']);
    print('SUCCESS: ? syntax worked!');
  } catch (e) {
    print('FAILURE: ? syntax failed: $e');
  }

  print('Testing ::text syntax...');
  try {
    await crdt.execute('INSERT INTO "$tenantId".dependencies (predecessor_task_id, successor_task_id, type) VALUES (\$1::text, \$2::text, \$3::text)', [
      't5',
      't6',
      'finishToStart',
    ]);
    print('SUCCESS: ::text syntax worked!');
  } catch (e) {
    print('FAILURE: ::text syntax failed: $e');
  }

  // await crdt.close();
  print('Done.');
}
