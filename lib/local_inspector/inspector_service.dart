import 'dart:convert';

import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:postgres/postgres.dart';

class InspectorTableDefinition {
  final String schema;
  final String table;
  final bool tenantScoped;
  final bool hasDeletedFlag;
  final Set<String> redactedColumns;
  final Set<String> sortableColumns;
  final Set<String> searchableColumns;
  final Map<String, String> filterColumns;
  final List<String> primaryKey;

  const InspectorTableDefinition({
    required this.schema,
    required this.table,
    this.tenantScoped = false,
    this.hasDeletedFlag = false,
    this.redactedColumns = const {},
    this.sortableColumns = const {},
    this.searchableColumns = const {},
    this.filterColumns = const {},
    this.primaryKey = const [],
  });

  String get key => '$schema.$table';

  String get quotedName =>
      '${_quoteIdentifier(schema)}.${_quoteIdentifier(table)}';
}

const inspectorTableDefinitions = <String, InspectorTableDefinition>{
  'auth.tenants': InspectorTableDefinition(
    schema: 'auth',
    table: 'tenants',
    sortableColumns: {'id', 'name', 'created_at', 'is_active'},
    searchableColumns: {'id', 'name'},
    filterColumns: {'id': 'id', 'name': 'name', 'isActive': 'is_active'},
    primaryKey: ['id'],
  ),
  'auth.users': InspectorTableDefinition(
    schema: 'auth',
    table: 'users',
    redactedColumns: {'password_hash'},
    sortableColumns: {'id', 'username', 'role', 'tenant_id', 'created_at'},
    searchableColumns: {'id', 'username', 'role', 'tenant_id'},
    filterColumns: {
      'id': 'id',
      'username': 'username',
      'role': 'role',
      'tenantId': 'tenant_id',
      'isActive': 'is_active',
    },
    primaryKey: ['id'],
  ),
  'auth.refresh_tokens': InspectorTableDefinition(
    schema: 'auth',
    table: 'refresh_tokens',
    redactedColumns: {'token_hash'},
    sortableColumns: {'id', 'user_id', 'expires_at'},
    searchableColumns: {'id', 'user_id'},
    filterColumns: {'id': 'id', 'userId': 'user_id', 'isRevoked': 'is_revoked'},
    primaryKey: ['id'],
  ),
  'public.tasks': InspectorTableDefinition(
    schema: 'public',
    table: 'tasks',
    tenantScoped: true,
    hasDeletedFlag: true,
    sortableColumns: {
      'id',
      'name',
      'start_date',
      'end_date',
      'last_updated',
      'modified',
    },
    searchableColumns: {'id', 'name', 'parent_id', 'resource_id', 'gantt_type'},
    filterColumns: {
      'id': 'id',
      'parentId': 'parent_id',
      'resourceId': 'resource_id',
      'ganttType': 'gantt_type',
    },
    primaryKey: ['tenant_id', 'id'],
  ),
  'public.dependencies': InspectorTableDefinition(
    schema: 'public',
    table: 'dependencies',
    tenantScoped: true,
    hasDeletedFlag: true,
    sortableColumns: {
      'predecessor_task_id',
      'successor_task_id',
      'last_updated',
      'modified',
    },
    searchableColumns: {
      'predecessor_task_id',
      'successor_task_id',
      'dependency_type',
    },
    filterColumns: {
      'predecessorId': 'predecessor_task_id',
      'successorId': 'successor_task_id',
      'dependencyType': 'dependency_type',
    },
    primaryKey: ['tenant_id', 'predecessor_task_id', 'successor_task_id'],
  ),
  'public.resources': InspectorTableDefinition(
    schema: 'public',
    table: 'resources',
    tenantScoped: true,
    hasDeletedFlag: true,
    sortableColumns: {
      'id',
      'name',
      'parent_id',
      'gantt_type',
      'sort_order',
      'last_updated',
      'modified',
    },
    searchableColumns: {'id', 'name', 'parent_id', 'gantt_type'},
    filterColumns: {
      'id': 'id',
      'parentId': 'parent_id',
      'ganttType': 'gantt_type',
    },
    primaryKey: ['tenant_id', 'id'],
  ),
  'public.project_metadata': InspectorTableDefinition(
    schema: 'public',
    table: 'project_metadata',
    tenantScoped: true,
    hasDeletedFlag: true,
    sortableColumns: {'tenant_id', 'last_reset_at', 'last_updated', 'modified'},
    searchableColumns: {'tenant_id'},
    filterColumns: {'tenantId': 'tenant_id'},
    primaryKey: ['tenant_id'],
  ),
  'public.licenses': InspectorTableDefinition(
    schema: 'public',
    table: 'licenses',
    redactedColumns: {'license_key'},
    sortableColumns: {
      'license_key',
      'tenant_id',
      'created_at',
      'expires_at',
      'last_updated',
      'modified',
    },
    searchableColumns: {'tenant_id', 'plan_tier'},
    filterColumns: {
      'tenantId': 'tenant_id',
      'planTier': 'plan_tier',
      'isRevoked': 'is_revoked',
    },
    primaryKey: ['license_key'],
  ),
};

class InspectorPage {
  final String tableKey;
  final String? tenantId;
  final List<Map<String, dynamic>> rows;
  final int total;
  final int limit;
  final int offset;
  final String? nextCursor;

  const InspectorPage({
    required this.tableKey,
    required this.tenantId,
    required this.rows,
    required this.total,
    required this.limit,
    required this.offset,
    required this.nextCursor,
  });

  Map<String, dynamic> toJson() => {
    'data': rows,
    'meta': {
      'table': tableKey,
      'tenantId': tenantId,
      'total': total,
      'limit': limit,
      'offset': offset,
      'nextCursor': nextCursor,
    },
  };
}

class InspectorDatabase {
  final Future<Connection> Function() _connectionFactory;
  Connection? _connection;

  InspectorDatabase(this._connectionFactory);

  Future<void> close() async {
    await _connection?.close();
    _connection = null;
  }

  InspectorTableDefinition definition(String tableKey) {
    final definition = inspectorTableDefinitions[tableKey];
    if (definition == null) {
      throw InspectorRequestException('Unknown application table: $tableKey');
    }
    return definition;
  }

  List<InspectorTableDefinition> get definitions =>
      inspectorTableDefinitions.values.toList(growable: false);

  Future<T> read<T>({
    String? tenantId,
    required Future<T> Function(TxSession session) action,
  }) async {
    var connection = _connection;
    if (connection == null || !connection.isOpen) {
      connection = await _connectionFactory();
      _connection = connection;
    }

    try {
      return await connection.runTx((session) async {
        await session.execute('SET TRANSACTION READ ONLY');
        if (tenantId != null) {
          await session.execute(
            Sql.named(
              "SELECT set_config('app.current_tenant', @tenantId, true)",
            ),
            parameters: {'tenantId': tenantId},
          );
        }
        return action(session);
      });
    } catch (error) {
      if (connection.isOpen) rethrow;
      _connection = null;
      final replacement = await _connectionFactory();
      _connection = replacement;
      return replacement.runTx((session) async {
        await session.execute('SET TRANSACTION READ ONLY');
        if (tenantId != null) {
          await session.execute(
            Sql.named(
              "SELECT set_config('app.current_tenant', @tenantId, true)",
            ),
            parameters: {'tenantId': tenantId},
          );
        }
        return action(session);
      });
    }
  }

  Future<InspectorPage> listRows(
    String tableKey, {
    String? tenantId,
    Map<String, String> filters = const {},
    String? search,
    bool includeDeleted = true,
    String? sort,
    int limit = 100,
    int offset = 0,
  }) async {
    final definition = this.definition(tableKey);
    final effectiveTenantId = tenantId ?? filters['tenantId'];
    if (definition.tenantScoped &&
        (effectiveTenantId == null || effectiveTenantId.isEmpty)) {
      throw InspectorRequestException(
        'tenantId is required for ${definition.key}',
      );
    }

    final boundedLimit = limit.clamp(1, 1000);
    final boundedOffset = offset.clamp(0, 1000000);
    return read(
      tenantId: definition.tenantScoped ? effectiveTenantId : null,
      action: (session) async {
        final where = <String>[];
        final parameters = <String, Object?>{};
        if (definition.tenantScoped) {
          where.add('"tenant_id" = @tenantId');
          parameters['tenantId'] = effectiveTenantId;
        }

        for (final entry in filters.entries) {
          if (entry.key == 'tenantId') continue;
          final column = definition.filterColumns[entry.key];
          if (column == null) {
            throw InspectorRequestException(
              'Unsupported filter for ${definition.key}: ${entry.key}',
            );
          }
          final parameterName = 'filter_${entry.key}';
          if (_isBooleanFilter(entry.key)) {
            parameters[parameterName] = _parseBoolean(entry.value, entry.key);
            where.add('"$column" = @$parameterName');
          } else {
            parameters[parameterName] = entry.value;
            where.add('"$column" = @$parameterName');
          }
        }

        if (!includeDeleted && definition.hasDeletedFlag) {
          where.add('COALESCE("is_deleted", 0) = 0');
        }

        if (search != null && search.trim().isNotEmpty) {
          final searchColumns = definition.searchableColumns
              .map((column) => 'CAST("$column" AS TEXT) ILIKE @search')
              .join(' OR ');
          if (searchColumns.isNotEmpty) {
            where.add('($searchColumns)');
            parameters['search'] = '%${search.trim()}%';
          }
        }

        final orderBy = _orderBy(definition, sort);
        final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
        final sql =
            '''
          SELECT *, COUNT(*) OVER() AS "__inspector_total"
          FROM ${definition.quotedName}
          $whereSql
          ORDER BY $orderBy
          LIMIT $boundedLimit OFFSET $boundedOffset
        ''';
        final result = await session.execute(
          Sql.named(sql),
          parameters: parameters,
        );
        var total = 0;
        final rows = <Map<String, dynamic>>[];
        for (final row in result) {
          final mapped = Map<String, dynamic>.from(row.toColumnMap());
          total = _asInt(mapped.remove('__inspector_total')) ?? total;
          rows.add(_sanitizeRow(mapped, definition));
        }
        final nextOffset = boundedOffset + rows.length;
        final nextCursor = nextOffset < total
            ? _encodeCursor(nextOffset)
            : null;
        return InspectorPage(
          tableKey: definition.key,
          tenantId: effectiveTenantId,
          rows: rows,
          total: total,
          limit: boundedLimit,
          offset: boundedOffset,
          nextCursor: nextCursor,
        );
      },
    );
  }

  Future<Map<String, dynamic>?> getRow(
    String tableKey, {
    String? tenantId,
    required Map<String, String> filters,
  }) async {
    final page = await listRows(
      tableKey,
      tenantId: tenantId,
      filters: filters,
      limit: 1,
    );
    return page.rows.isEmpty ? null : page.rows.first;
  }

  Future<List<Map<String, dynamic>>> schemaMetadata() async {
    return read(
      action: (session) async {
        final output = <Map<String, dynamic>>[];
        for (final definition in definitions) {
          final columnsResult = await session.execute(
            Sql.named('''
            SELECT column_name, data_type, udt_name, is_nullable,
                   ordinal_position, column_default
            FROM information_schema.columns
            WHERE table_schema = @schema AND table_name = @table
            ORDER BY ordinal_position
          '''),
            parameters: {
              'schema': definition.schema,
              'table': definition.table,
            },
          );
          final primaryKeyResult = await session.execute(
            Sql.named('''
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
             AND tc.table_schema = kcu.table_schema
             AND tc.table_name = kcu.table_name
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = @schema
              AND tc.table_name = @table
            ORDER BY kcu.ordinal_position
          '''),
            parameters: {
              'schema': definition.schema,
              'table': definition.table,
            },
          );
          final rlsResult = await session.execute(
            Sql.named('''
            SELECT c.relrowsecurity, c.relforcerowsecurity,
                   COALESCE(
                     json_agg(json_build_object('name', p.policyname))
                       FILTER (WHERE p.policyname IS NOT NULL),
                     '[]'::json
                   ) AS policies
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_policies p
              ON p.schemaname = n.nspname AND p.tablename = c.relname
            WHERE n.nspname = @schema AND c.relname = @table
            GROUP BY c.relrowsecurity, c.relforcerowsecurity
          '''),
            parameters: {
              'schema': definition.schema,
              'table': definition.table,
            },
          );
          final rls = rlsResult.isEmpty ? null : rlsResult.first.toColumnMap();
          output.add({
            'schema': definition.schema,
            'table': definition.table,
            'tenantScoped': definition.tenantScoped,
            'redactedColumns': definition.redactedColumns.toList()..sort(),
            'primaryKey': primaryKeyResult
                .map((row) => row[0].toString())
                .toList(growable: false),
            'declaredPrimaryKey': definition.primaryKey,
            'columns': columnsResult
                .map((row) => _jsonSafe(row.toColumnMap()))
                .toList(growable: false),
            'rls': rls == null ? null : _jsonSafe(rls),
          });
        }
        return output;
      },
    );
  }

  Future<List<Map<String, dynamic>>> databaseSummary() async {
    final tenantIds = await allTenantIds();
    final counts = <String, Map<String, dynamic>>{};
    for (final definition in definitions) {
      var total = 0;
      var deleted = 0;
      if (definition.tenantScoped) {
        for (final tenantId in tenantIds) {
          final result = await _countRows(definition, tenantId);
          total += result.total;
          deleted += result.deleted;
        }
      } else {
        final result = await _countRows(definition, null);
        total = result.total;
        deleted = result.deleted;
      }
      counts[definition.key] = {
        'schema': definition.schema,
        'table': definition.table,
        'total': total,
        'deleted': definition.hasDeletedFlag ? deleted : null,
      };
    }
    return counts.values.toList(growable: false);
  }

  Future<List<String>> allTenantIds() async {
    final tenantIds = <String>[];
    var offset = 0;
    while (true) {
      final page = await listRows('auth.tenants', limit: 1000, offset: offset);
      tenantIds.addAll(
        page.rows.map((row) => row['id']?.toString()).whereType<String>(),
      );
      if (page.nextCursor == null || page.rows.isEmpty) break;
      offset += page.rows.length;
    }
    return tenantIds;
  }

  Future<Map<String, dynamic>> tenantSnapshot(
    String tenantId, {
    bool includeDeleted = true,
    int limit = 10000,
  }) async {
    final tasks = await listRows(
      'public.tasks',
      tenantId: tenantId,
      includeDeleted: includeDeleted,
      limit: limit,
    );
    final dependencies = await listRows(
      'public.dependencies',
      tenantId: tenantId,
      includeDeleted: includeDeleted,
      limit: limit,
    );
    final resources = await listRows(
      'public.resources',
      tenantId: tenantId,
      includeDeleted: includeDeleted,
      limit: limit,
    );
    final metadata = await getRow(
      'public.project_metadata',
      tenantId: tenantId,
      filters: {'tenantId': tenantId},
    );
    return {
      'tenantId': tenantId,
      'tasks': tasks.rows,
      'dependencies': dependencies.rows,
      'resources': resources.rows,
      'projectMetadata': metadata,
      'counts': {
        'tasks': tasks.total,
        'dependencies': dependencies.total,
        'resources': resources.total,
      },
      'truncated':
          tasks.total > tasks.rows.length ||
          dependencies.total > dependencies.rows.length ||
          resources.total > resources.rows.length,
    };
  }

  Future<Map<String, List<Map<String, dynamic>>>> tenantMerkleRows(
    String tenantId,
  ) async {
    return read(
      tenantId: tenantId,
      action: (session) async {
        Future<List<Map<String, dynamic>>> load(String table) async {
          final definition = this.definition('public.$table');
          final result = await session.execute(
            Sql.named(
              'SELECT * FROM ${definition.quotedName} WHERE "tenant_id" = @tenantId',
            ),
            parameters: {'tenantId': tenantId},
          );
          return result
              .map((row) => Map<String, dynamic>.from(row.toColumnMap()))
              .toList(growable: false);
        }

        return {
          'tasks': await load('tasks'),
          'dependencies': await load('dependencies'),
          'resources': await load('resources'),
        };
      },
    );
  }

  Future<List<Map<String, dynamic>>> tenantMerkleEntities(
    String tenantId,
    String prefix,
  ) async {
    final rows = await tenantMerkleRows(tenantId);
    final formatter = CrdtService();
    final entities = <Map<String, dynamic>>[];
    for (final row in rows['tasks']!) {
      if (_prefix(row) == prefix) {
        entities.add({
          'table': 'tasks',
          'operation': formatter.formatTaskOperation(row),
        });
      }
    }
    for (final row in rows['dependencies']!) {
      if (_prefix(row) == prefix) {
        final operation = formatter.formatDependencyOperation(row);
        if (operation != null) {
          entities.add({'table': 'dependencies', 'operation': operation});
        }
      }
    }
    for (final row in rows['resources']!) {
      if (_prefix(row) == prefix) {
        entities.add({
          'table': 'resources',
          'operation': formatter.formatResourceOperation(row),
        });
      }
    }
    return entities;
  }

  static String _prefix(Map<String, dynamic> row) =>
      MerkleHashNormalizer.merkleMinutePrefix(row['last_updated']?.toString());

  Future<_RowCounts> _countRows(
    InspectorTableDefinition definition,
    String? tenantId,
  ) async {
    return read(
      tenantId: definition.tenantScoped ? tenantId : null,
      action: (session) async {
        final where = <String>[];
        final parameters = <String, Object?>{};
        if (definition.tenantScoped) {
          where.add('"tenant_id" = @tenantId');
          parameters['tenantId'] = tenantId;
        }
        final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
        final totalResult = await session.execute(
          Sql.named(
            'SELECT COUNT(*) AS total FROM ${definition.quotedName} $whereSql',
          ),
          parameters: parameters,
        );
        var deleted = 0;
        if (definition.hasDeletedFlag) {
          final deletedWhere = whereSql.isEmpty ? 'WHERE' : '$whereSql AND';
          final deletedResult = await session.execute(
            Sql.named(
              'SELECT COUNT(*) AS deleted FROM ${definition.quotedName} $deletedWhere COALESCE("is_deleted", 0) <> 0',
            ),
            parameters: parameters,
          );
          deleted = _asInt(deletedResult.first.toColumnMap()['deleted']) ?? 0;
        }
        return _RowCounts(
          total: _asInt(totalResult.first.toColumnMap()['total']) ?? 0,
          deleted: deleted,
        );
      },
    );
  }

  String _orderBy(InspectorTableDefinition definition, String? sort) {
    if (sort == null || sort.isEmpty) {
      final column = definition.sortableColumns.isEmpty
          ? definition.primaryKey.first
          : definition.sortableColumns.first;
      return '"$column" ASC';
    }
    final descending = sort.startsWith('-');
    final column = descending ? sort.substring(1) : sort;
    if (!definition.sortableColumns.contains(column)) {
      throw InspectorRequestException(
        'Unsupported sort column for ${definition.key}: $column',
      );
    }
    return '"$column" ${descending ? 'DESC' : 'ASC'}';
  }

  Map<String, dynamic> _sanitizeRow(
    Map<String, dynamic> row,
    InspectorTableDefinition definition,
  ) {
    final result = <String, dynamic>{};
    for (final entry in row.entries) {
      if (definition.redactedColumns.contains(entry.key)) continue;
      result[entry.key] = _jsonSafe(entry.value);
    }
    if (definition.redactedColumns.isNotEmpty) {
      result['_redactedFields'] = definition.redactedColumns.toList()..sort();
    }
    return result;
  }

  static bool _isBooleanFilter(String key) =>
      key == 'isActive' || key == 'isRevoked';

  static bool _parseBoolean(String value, String key) {
    switch (value.toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
      default:
        throw InspectorRequestException('Invalid boolean for $key: $value');
    }
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String _encodeCursor(int offset) =>
      base64Url.encode(utf8.encode(offset.toString()));

  static dynamic _jsonSafe(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is List<int>) return base64Url.encode(value);
    if (value is List) return value.map(_jsonSafe).toList(growable: false);
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _jsonSafe(item)),
      );
    }
    return value.toString();
  }
}

class InspectorRequestException implements Exception {
  final String message;

  const InspectorRequestException(this.message);

  @override
  String toString() => message;
}

class _RowCounts {
  final int total;
  final int deleted;

  const _RowCounts({required this.total, required this.deleted});
}

String _quoteIdentifier(String identifier) =>
    '"${identifier.replaceAll('"', '""')}"';
