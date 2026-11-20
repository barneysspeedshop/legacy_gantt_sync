import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:postgres_crdt/postgres_crdt.dart' hide Hlc;
import 'package:postgres/postgres.dart' as pg;

import 'legacy_modified_clock_repair.dart';
import 'package:legacy_gantt_sync/utils/logger.dart';
import 'package:legacy_gantt_sync/utils/retry_utils.dart';

class CrdtService {
  PostgresCrdt? _crdt;
  final Completer<PostgresCrdt> _initCompleter = Completer();

  Future<void> init() async {
    if (_crdt != null) return;

    try {
      _crdt = await _openInitializedCrdt(description: 'Connect to Main DB');

      _initCompleter.complete(_crdt);
      JsonLogger.info('DB_INIT_SUCCESS', {});
    } catch (e) {
      JsonLogger.error('DB_INIT_FAIL', {'error': e.toString()});
      _initCompleter.completeError(e);
      rethrow;
    }
  }

  Future<PostgresCrdt> _openInitializedCrdt({
    required String description,
    int? maxRetries,
  }) async {
    final opened = await retryForever(
      _openWithSchemaLock,
      description: description,
      maxRetries: maxRetries,
    );
    try {
      await _initTables(opened.crdt);
      return opened.crdt;
    } finally {
      // This dedicated session owns the database-scoped advisory lock. Closing
      // it releases the lock without reserving a CRDT pool connection.
      await opened.guard.close();
    }
  }

  Future<({pg.Connection guard, PostgresCrdt crdt})>
  _openWithSchemaLock() async {
    final connection = await pg.Connection.open(
      pg.Endpoint(
        host: Platform.environment['DB_HOST'] ?? 'localhost',
        port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
        database: Platform.environment['DB_NAME'] ?? 'legacy_gantt',
        username:
            Platform.environment['DB_USER'] ??
            (throw ArgumentError('DB_USER is required')),
        password:
            Platform.environment['DB_PASS'] ??
            (throw ArgumentError('DB_PASS is required')),
      ),
      settings: pg.ConnectionSettings(sslMode: _getSslMode()),
    );
    try {
      await connection.execute(
        "SELECT pg_advisory_lock(hashtext('legacy_gantt_sync'), hashtext('schema_init'))",
      );
      final repaired = await repairLegacyModifiedClocks(connection);
      if (repaired > 0) {
        JsonLogger.info('LEGACY_MODIFIED_CLOCKS_REPAIRED', {'count': repaired});
      }
      final crdt = await PostgresCrdt.open(
        Platform.environment['DB_NAME'] ?? 'legacy_gantt',
        host: Platform.environment['DB_HOST'] ?? 'localhost',
        port: int.parse(Platform.environment['DB_PORT'] ?? '5432'),
        username:
            Platform.environment['DB_USER'] ??
            (throw ArgumentError('DB_USER is required')),
        password:
            Platform.environment['DB_PASS'] ??
            (throw ArgumentError('DB_PASS is required')),
        sslMode: _getSslMode(),
      );
      return (guard: connection, crdt: crdt);
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  Future<void> _initTables(PostgresCrdt crdt) async {
    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
        id TEXT NOT NULL,
        tenant_id TEXT NOT NULL,
        name TEXT,
        gantt_type TEXT,
        start_date TEXT, -- Changed to TEXT for HLC
        end_date TEXT,   -- Changed to TEXT for HLC
        parent_id TEXT,
        last_updated TEXT, -- Changed to TEXT for HLC
        deleted_at TEXT,   -- Changed to TEXT for HLC
        color TEXT,
        text_color TEXT,
        uses_work_calendar BOOLEAN DEFAULT FALSE,
        completion FLOAT8 DEFAULT 0.0,
        resource_id TEXT,
        baseline_start TEXT, -- Changed to TEXT for HLC
        baseline_end TEXT,   -- Changed to TEXT for HLC
        notes TEXT,
        row_id TEXT,
        propagates_move_to_children BOOLEAN DEFAULT TRUE,
        resize_policy TEXT DEFAULT 'none',
        metadata_json TEXT,
        field_timestamps TEXT,
        PRIMARY KEY (tenant_id, id)
      )
    ''');

    await crdt.execute(
      'ALTER TABLE tasks ADD COLUMN IF NOT EXISTS metadata_json TEXT',
    );
    await crdt.execute(
      'ALTER TABLE tasks ADD COLUMN IF NOT EXISTS field_timestamps TEXT',
    );

    try {
      await crdt.execute(
        'ALTER TABLE tasks ALTER COLUMN last_updated TYPE TEXT USING last_updated::text',
      );
      await crdt.execute(
        'ALTER TABLE tasks ALTER COLUMN deleted_at TYPE TEXT USING deleted_at::text',
      );
      await crdt.execute(
        'ALTER TABLE tasks ALTER COLUMN start_date TYPE TEXT USING start_date::text',
      );
      await crdt.execute(
        'ALTER TABLE tasks ALTER COLUMN end_date TYPE TEXT USING end_date::text',
      );
      await crdt.execute(
        'ALTER TABLE tasks ALTER COLUMN baseline_start TYPE TEXT USING baseline_start::text',
      );
      await crdt.execute(
        'ALTER TABLE tasks ALTER COLUMN baseline_end TYPE TEXT USING baseline_end::text',
      );
    } catch (_) {}

    try {
      await crdt.execute(
        'ALTER TABLE tasks ADD COLUMN IF NOT EXISTS row_id TEXT',
      );
      await crdt.execute(
        'ALTER TABLE tasks ADD COLUMN IF NOT EXISTS propagates_move_to_children BOOLEAN DEFAULT TRUE',
      );
      await crdt.execute(
        'ALTER TABLE tasks ADD COLUMN IF NOT EXISTS resize_policy TEXT DEFAULT \'none\'',
      );
    } catch (_) {}

    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS dependencies (
        predecessor_task_id TEXT NOT NULL,
        successor_task_id TEXT NOT NULL,
        tenant_id TEXT NOT NULL,
        dependency_type TEXT NOT NULL DEFAULT 'finishToStart',
        lag TEXT,          -- Changed to TEXT for HLC (Duration/int stored as string?) Or keep int? Lag is duration, not Timestamp. Keep INT for lag? But HLC might be used? No, lag is duration. But let's check legacy code. It was BIGINT.
        last_updated TEXT, -- Changed to TEXT for HLC
        deleted_at TEXT,   -- Changed to TEXT for HLC
        PRIMARY KEY (tenant_id, predecessor_task_id, successor_task_id)
      )
    ''');

    try {
      await crdt.execute(
        'ALTER TABLE dependencies ALTER COLUMN last_updated TYPE TEXT USING last_updated::text',
      );
      await crdt.execute(
        'ALTER TABLE dependencies ALTER COLUMN deleted_at TYPE TEXT USING deleted_at::text',
      );
    } catch (_) {}

    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS resources (
        id TEXT NOT NULL,
        tenant_id TEXT NOT NULL,
        name TEXT,
        parent_id TEXT,
        gantt_type TEXT,
        is_expanded BOOLEAN NOT NULL DEFAULT TRUE,
        last_updated TEXT, -- Changed to TEXT for HLC
        deleted_at TEXT,   -- Changed to TEXT for HLC
        PRIMARY KEY (tenant_id, id)
      )
    ''');

    try {
      await crdt.execute(
        'ALTER TABLE resources ALTER COLUMN last_updated TYPE TEXT USING last_updated::text',
      );
      await crdt.execute(
        'ALTER TABLE resources ALTER COLUMN deleted_at TYPE TEXT USING deleted_at::text',
      );
      await crdt.execute(
        'ALTER TABLE resources ADD COLUMN IF NOT EXISTS sort_order FLOAT8',
      );
    } catch (_) {}

    await crdt.execute(
      'ALTER TABLE resources ADD COLUMN IF NOT EXISTS metadata_json TEXT',
    );

    await crdt.execute('''
      CREATE TABLE IF NOT EXISTS project_metadata (
        tenant_id TEXT NOT NULL,
        last_reset_at TEXT, -- Changed to TEXT for HLC
        last_updated TEXT,  -- Changed to TEXT for HLC
        PRIMARY KEY (tenant_id)
      )
    ''');

    try {
      await crdt.execute(
        'ALTER TABLE project_metadata ALTER COLUMN last_reset_at TYPE TEXT USING last_reset_at::text',
      );
      await crdt.execute(
        'ALTER TABLE project_metadata ALTER COLUMN last_updated TYPE TEXT USING last_updated::text',
      );
    } catch (_) {}

    await _enableRls(crdt, 'tasks');
    await _enableRls(crdt, 'dependencies');
    await _enableRls(crdt, 'resources');
    await crdt.execute(
      'ALTER TABLE project_metadata DISABLE ROW LEVEL SECURITY',
    );
  }

  Future<void> _enableRls(PostgresCrdt crdt, String tableName) async {
    await crdt.execute('ALTER TABLE $tableName ENABLE ROW LEVEL SECURITY');
    await crdt.execute('ALTER TABLE $tableName FORCE ROW LEVEL SECURITY');

    try {
      await crdt.execute('''
        CREATE POLICY tenant_isolation ON $tableName
        USING (tenant_id = current_setting('app.current_tenant')::text)
        WITH CHECK (tenant_id = current_setting('app.current_tenant')::text)
      ''');
    } catch (_) {}
  }

  Future<T> runTransaction<T>(
    String tenantId,
    Future<T> Function(CrdtExecutor crdt) callback,
  ) async {
    var crdt = _crdt ?? await _initCompleter.future;

    try {
      return await _performTransaction(crdt, tenantId, callback);
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('socketexception') ||
          errorStr.contains('connection closed') ||
          errorStr.contains('connection reset')) {
        JsonLogger.warn('DB_CONNECTION_LOST', {
          'error': e.toString(),
          'action': 'reconnecting',
        });

        _crdt = null; // Clear bad instance

        try {
          _crdt = await _openInitializedCrdt(
            description: 'Reconnect to Main DB',
            maxRetries: 3,
          );
          crdt = _crdt!;
          return await _performTransaction(crdt, tenantId, callback);
        } catch (reconnectError) {
          JsonLogger.error('DB_RECONNECT_FAIL', {
            'error': reconnectError.toString(),
          });
          rethrow;
        }
      }
      rethrow;
    }
  }

  Future<T> _performTransaction<T>(
    PostgresCrdt crdt,
    String tenantId,
    Future<T> Function(CrdtExecutor txn) callback,
  ) async {
    late T result;
    await crdt.transaction((txn) async {
      await txn.execute("SET LOCAL app.current_tenant = '$tenantId'");
      result = await callback(txn);
    });
    return result;
  }

  Future<List<Map<String, dynamic>>> query(
    String tenantId,
    String sql, [
    List<dynamic>? params,
  ]) async {
    return runTransaction(tenantId, (txn) async {
      return await txn.query(sql, params);
    });
  }

  Future<void> streamSyncData(
    String tenantId, {
    String? lastSynced,
    required void Function(Map<String, dynamic> event) onEvent,
  }) async {
    await runTransaction(tenantId, (txn) async {
      String whereClause;
      List<Object?> params = [];
      if (lastSynced != null) {
        whereClause =
            'WHERE tenant_id = ? AND (last_updated > ? OR deleted_at > ?)';
        JsonLogger.info('DELTA_SYNC_QUERY', {
          'where': whereClause,
          'lastSynced': lastSynced,
          'tenantId': tenantId,
        });
        params = [tenantId, lastSynced, lastSynced];
      } else {
        whereClause =
            'WHERE tenant_id = ? AND (is_deleted = 0 OR is_deleted IS NULL)';
        JsonLogger.info('FULL_SYNC_QUERY', {
          'where': whereClause,
          'tenantId': tenantId,
        });
        params = [tenantId];
      }

      final tasks = await txn.query('SELECT * FROM tasks $whereClause', params);
      final allDeps = await txn.query(
        'SELECT * FROM dependencies $whereClause',
        params,
      );
      final allResources = await txn.query(
        'SELECT * FROM resources $whereClause',
        params,
      );

      final totalCount = tasks.length + allDeps.length + allResources.length;

      final projectMetadata = await txn.query(
        'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ?',
        [tenantId],
      );
      if (projectMetadata.isNotEmpty) {
        final lastResetAt = projectMetadata.first['last_reset_at'] as String?;
        print(
          'DEBUG: Syncing tenant $tenantId. Last Reset At: $lastResetAt, Client Last Synced: $lastSynced',
        );
        if (lastResetAt != null &&
            (lastSynced == null || lastResetAt.compareTo(lastSynced) > 0)) {
          print('DEBUG: Emitting RESET_DATA for tenant $tenantId');
          onEvent({
            'type': 'RESET_DATA',
            'data': <String, dynamic>{},
            'timestamp': lastResetAt,
            'actorId': 'server-sync-reset',
          });
        }
      }

      onEvent({
        'type': 'SYNC_METADATA',
        'data': <String, dynamic>{'totalOperations': totalCount},
        'timestamp': Hlc.fromDate(
          DateTime.now(),
          'server-sync',
        ).toString(), // Proper HLC
        'actorId': 'server-sync',
      });
      final List<Map<String, dynamic>> operations = [];

      for (final row in tasks) {
        // ... (truncated for brevity, logic same)
        // Note: row iteration logic remains same since envelope timestamps should already be HLC strings from DB
        // But for fresh envelope creation below:

        operations.add(formatTaskOperation(row));
      }

      for (final record in allDeps) {
        final op = formatDependencyOperation(record);
        if (op != null) operations.add(op);
      }

      for (final record in allResources) {
        operations.add(formatResourceOperation(record));
      }

      const batchSize = 100;
      for (var i = 0; i < operations.length; i += batchSize) {
        final end = (i + batchSize < operations.length)
            ? i + batchSize
            : operations.length;
        final chunk = operations.sublist(i, end);

        onEvent({
          'type': 'BATCH_UPDATE',
          'data': <String, dynamic>{'operations': chunk},
          'timestamp': Hlc.fromDate(DateTime.now(), 'server-sync').toString(),
          'actorId': 'server-sync',
        });
      }
    });
  }

  SslMode _getSslMode() {
    final modeStr = Platform.environment['DB_SSL_MODE']?.toLowerCase();
    if (modeStr == 'disable') {
      return SslMode.disable;
    }
    return SslMode.require;
  }

  Map<String, dynamic> formatTaskOperation(Map<String, dynamic> row) {
    final isDeleted = _toBool(row['is_deleted']);
    final metadata = ProtobufMapper.metadataFromJson({
      'metadataJson': row['metadata_json'],
    });

    final cleanData = <String, dynamic>{
      'id': row['id']?.toString(),
      'name': row['name'],
      'start_date': MerkleHashNormalizer.formatProtocolDate(row['start_date']),
      'end_date': MerkleHashNormalizer.formatProtocolDate(
        row['end_date'],
        fallback: DateTime.utc(1970, 1, 2).toIso8601String(),
      ),
      'parentId': row['parent_id']?.toString(),
      'completion': row['completion'],
      'resourceId': row['resource_id'],
      'notes': row['notes'],
      'isMilestone': row['gantt_type'] == 'milestone',
      'isSummary':
          row['gantt_type'] == 'project' || row['gantt_type'] == 'summary',
      'isDeleted': isDeleted,
      'rowId': row['row_id']?.toString(),
      'metadataJson': jsonEncode(
        MerkleHashNormalizer.completeTaskMetadata({
          ...metadata,
          'color': MerkleHashNormalizer.normalizeColorHex(row['color']),
          'textColor': MerkleHashNormalizer.normalizeColorHex(
            row['text_color'],
          ),
          'originalId': metadata['originalId'],
          'usesWorkCalendar': _toBool(row['uses_work_calendar']),
          'propagatesMoveToChildren':
              row['propagates_move_to_children'] == null ||
              _toBool(row['propagates_move_to_children']),
          'resizePolicy': MerkleHashNormalizer.normalizeResizePolicy(
            row['resize_policy'],
          ),
          'baselineStart': MerkleHashNormalizer.formatProtocolDateOrNull(
            row['baseline_start'],
          ),
          'baselineEnd': MerkleHashNormalizer.formatProtocolDateOrNull(
            row['baseline_end'],
          ),
        }),
      ),
    };

    final lastUpdated = recordTimestamp(row);

    final envelope = {
      'type': isDeleted ? 'DELETE_TASK' : 'UPDATE_TASK',
      'data': cleanData,
      'timestamp': lastUpdated,
      'actorId': 'server-sync',
    };

    cleanData['lastUpdated'] = lastUpdated;
    final fieldTimestamps = row['field_timestamps'];
    final storedClocks = fieldTimestamps is String && fieldTimestamps.isNotEmpty
        ? jsonDecode(fieldTimestamps) as Map<String, dynamic>
        : <String, dynamic>{};
    cleanData['fieldTimestamps'] =
        MerkleHashNormalizer.normalizeTaskFieldTimestamps(
          fieldTimestamps: storedClocks.map(
            (key, value) => MapEntry(key, value as String),
          ),
          lastUpdated: lastUpdated,
          metadata: ProtobufMapper.metadataFromJson(cleanData),
        );

    return envelope;
  }

  Map<String, dynamic>? formatDependencyOperation(Map<String, dynamic> record) {
    final isDeleted = _toBool(record['is_deleted']);

    final cleanData = {
      'predecessorTaskId': record['predecessor_task_id']?.toString(),
      'successorTaskId': record['successor_task_id']?.toString(),
      'type': isDeleted ? 'DELETE' : record['dependency_type'],
      'lag': isDeleted || record['lag'] == null
          ? 0
          : int.parse(record['lag'].toString()),
    };

    if (cleanData['predecessorTaskId'] == null ||
        cleanData['successorTaskId'] == null) {
      return null;
    }

    final lastUpdated = recordTimestamp(record);
    cleanData['lastUpdated'] = lastUpdated;

    return {
      'type': isDeleted ? 'DELETE_DEPENDENCY' : 'INSERT_DEPENDENCY',
      'data': cleanData,
      'timestamp': lastUpdated,
      'actorId': 'server-sync',
    };
  }

  Map<String, dynamic> formatResourceOperation(Map<String, dynamic> record) {
    final isDeleted = _toBool(record['is_deleted']);

    final cleanData = {
      'id': record['id']?.toString(),
      'name': record['name'],
      'parentId': record['parent_id']?.toString(),
      'isExpanded':
          record['is_expanded'] == null || _toBool(record['is_expanded']),
      'type': record['gantt_type'] ?? 'person',
      'isDeleted': isDeleted,
      'metadataJson': jsonEncode(
        MerkleHashNormalizer.normalizeResourceMetadata({
          ...ProtobufMapper.metadataFromJson({
            'metadataJson': record['metadata_json'],
          }),
          'ganttType': record['gantt_type'] ?? 'person',
          'isExpanded':
              record['is_expanded'] == null || _toBool(record['is_expanded']),
        }, type: record['gantt_type']?.toString() ?? 'person'),
      ),
    };

    if (isDeleted) {
      cleanData.remove('isExpanded');
      cleanData.addAll({
        'name': '',
        'parentId': '',
        'type': 'person',
        'metadataJson': '{}',
      });
    }

    final lastUpdated = recordTimestamp(record);
    cleanData['lastUpdated'] = lastUpdated;

    final envelope = {
      'type': isDeleted ? 'DELETE_RESOURCE' : 'INSERT_RESOURCE',
      'data': cleanData,
      'timestamp': lastUpdated,
      'actorId': 'server-sync',
    };

    return envelope;
  }

  /// A tombstone's causal clock includes its deletion, even for older rows
  /// whose last_updated field was not advanced when deleted_at was written.
  static String recordTimestamp(Map<String, dynamic> row) {
    final updated = row['last_updated']?.toString();
    final deleted = _toBool(row['is_deleted'])
        ? row['deleted_at']?.toString()
        : null;
    if (updated == null || updated.isEmpty) {
      return deleted ?? Hlc.zero.toString();
    }
    if (deleted == null || deleted.isEmpty) return updated;
    return Hlc.parse(deleted) > Hlc.parse(updated) ? deleted : updated;
  }

  static bool _toBool(dynamic value) =>
      value == true || value == 1 || value == '1' || value == 'true';
}
