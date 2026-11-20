import 'dart:async';
import 'dart:convert';

import 'package:legacy_gantt_sync/local_inspector/inspector_service.dart';
import 'package:legacy_gantt_sync/server/services/merkle_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

class InspectorHandler {
  final InspectorDatabase database;

  InspectorHandler(this.database);

  Router get router {
    final router = Router();
    router.get('/schema', _schema);
    router.get('/schema/<schema>/<table>', _tableSchema);
    router.get('/tables', _tables);
    router.get('/database/summary', _databaseSummary);
    router.get('/database/export', _databaseExport);
    router.get('/auth/tenants', _authTenants);
    router.get('/auth/tenants/<tenantId>', _authTenant);
    router.get('/auth/users', _authUsers);
    router.get('/auth/users/<userId>', _authUser);
    router.get('/auth/refresh-tokens', _refreshTokens);
    router.get('/auth/refresh-tokens/<tokenId>', _refreshToken);
    router.get('/project/tasks', _tasks);
    router.get('/project/tasks/<tenantId>/<taskId>', _task);
    router.get('/project/dependencies', _dependencies);
    router.get(
      '/project/dependencies/<tenantId>/<predecessorId>/<successorId>',
      _dependency,
    );
    router.get('/project/resources', _resources);
    router.get('/project/resources/<tenantId>/<resourceId>', _resource);
    router.get('/project/metadata/<tenantId>', _metadata);
    router.get('/licenses', _licenses);
    router.get('/licenses/<tenantId>', _tenantLicenses);
    router.get('/tenants/<tenantId>/snapshot', _snapshot);
    router.get('/sync/merkle/<tenantId>/root', _merkleRoot);
    router.get('/sync/merkle/<tenantId>/nodes', _merkleNode);
    router.get('/sync/merkle/<tenantId>/entities', _merkleEntities);
    router.get('/tables/<schema>/<table>', _genericTable);
    return router;
  }

  Future<Response> _schema(Request request) async {
    return _json({'data': await database.schemaMetadata()});
  }

  Future<Response> _tableSchema(
    Request request,
    String schema,
    String table,
  ) async {
    final key = '$schema.$table';
    database.definition(key);
    final metadata = await database.schemaMetadata();
    final match = metadata.where(
      (entry) => entry['schema'] == schema && entry['table'] == table,
    );
    if (match.isEmpty) return Response.notFound('Table not found');
    return _json({'data': match.first});
  }

  Future<Response> _tables(Request request) async {
    return _json({
      'data': database.definitions
          .map(
            (definition) => {
              'schema': definition.schema,
              'table': definition.table,
              'key': definition.key,
              'tenantScoped': definition.tenantScoped,
              'primaryKey': definition.primaryKey,
              'redactedColumns': definition.redactedColumns.toList()..sort(),
            },
          )
          .toList(growable: false),
    });
  }

  Future<Response> _databaseSummary(Request request) async {
    return _json({'data': await database.databaseSummary()});
  }

  Future<Response> _databaseExport(Request request) async {
    final tableKeys = request.url.queryParameters['tables']
        ?.split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final selected =
        tableKeys ??
        database.definitions.map((definition) => definition.key).toList();
    for (final tableKey in selected) {
      database.definition(tableKey);
    }
    final stream = StreamController<List<int>>();
    () async {
      try {
        final tenantIds = request.url.queryParameters['tenantId'] != null
            ? [request.url.queryParameters['tenantId']!]
            : await database.allTenantIds();
        for (final tableKey in selected) {
          final definition = database.definition(tableKey);
          final scopes = definition.tenantScoped ? tenantIds : <String?>[null];
          for (final tenantId in scopes) {
            var offset = 0;
            final filters =
                !definition.tenantScoped &&
                    tenantId != null &&
                    definition.filterColumns.containsKey('tenantId')
                ? {'tenantId': tenantId}
                : const <String, String>{};
            while (true) {
              final page = await database.listRows(
                tableKey,
                tenantId: tenantId,
                filters: filters,
                includeDeleted: _includeDeleted(request),
                limit: 1000,
                offset: offset,
              );
              for (final row in page.rows) {
                stream.add(
                  utf8.encode(
                    '${jsonEncode({'table': tableKey, 'row': row})}\n',
                  ),
                );
              }
              if (page.nextCursor == null || page.rows.isEmpty) break;
              offset += page.rows.length;
            }
          }
        }
      } catch (error, stackTrace) {
        stream.addError(error, stackTrace);
      } finally {
        await stream.close();
      }
    }();
    return Response.ok(
      stream.stream,
      headers: {
        'Content-Type': 'application/x-ndjson; charset=utf-8',
        'Content-Disposition': 'attachment; filename="database-export.jsonl"',
      },
    );
  }

  Future<Response> _authTenants(Request request) =>
      _list(request, 'auth.tenants');

  Future<Response> _authTenant(Request request, String tenantId) =>
      _one(request, 'auth.tenants', {'id': tenantId});

  Future<Response> _authUsers(Request request) => _list(request, 'auth.users');

  Future<Response> _authUser(Request request, String userId) =>
      _one(request, 'auth.users', {'id': userId});

  Future<Response> _refreshTokens(Request request) =>
      _list(request, 'auth.refresh_tokens');

  Future<Response> _refreshToken(Request request, String tokenId) =>
      _one(request, 'auth.refresh_tokens', {'id': tokenId});

  Future<Response> _tasks(Request request) => _list(request, 'public.tasks');

  Future<Response> _task(Request request, String tenantId, String taskId) =>
      _one(request, 'public.tasks', {'id': taskId}, tenantId: tenantId);

  Future<Response> _dependencies(Request request) =>
      _list(request, 'public.dependencies');

  Future<Response> _dependency(
    Request request,
    String tenantId,
    String predecessorId,
    String successorId,
  ) => _one(request, 'public.dependencies', {
    'predecessorId': predecessorId,
    'successorId': successorId,
  }, tenantId: tenantId);

  Future<Response> _resources(Request request) =>
      _list(request, 'public.resources');

  Future<Response> _resource(
    Request request,
    String tenantId,
    String resourceId,
  ) =>
      _one(request, 'public.resources', {'id': resourceId}, tenantId: tenantId);

  Future<Response> _metadata(Request request, String tenantId) => _one(
    request,
    'public.project_metadata',
    {'tenantId': tenantId},
    tenantId: tenantId,
  );

  Future<Response> _licenses(Request request) =>
      _list(request, 'public.licenses');

  Future<Response> _tenantLicenses(Request request, String tenantId) =>
      _list(request, 'public.licenses', filters: {'tenantId': tenantId});

  Future<Response> _snapshot(Request request, String tenantId) async {
    final snapshot = await database.tenantSnapshot(
      tenantId,
      includeDeleted: _includeDeleted(request),
    );
    return _json({'data': snapshot});
  }

  Future<Response> _merkleRoot(Request request, String tenantId) async {
    final rows = await database.tenantMerkleRows(tenantId);
    final tree = MerkleService.buildTreeFromRows(
      tasks: rows['tasks']!,
      dependencies: rows['dependencies']!,
      resources: rows['resources']!,
      resetTimestamp: MerkleService.resetTimestampFromRows(
        rows['metadata'] ?? [],
      ),
    );
    return _json({
      'data': {'tenantId': tenantId, 'root': tree.root.hash},
    });
  }

  Future<Response> _merkleNode(Request request, String tenantId) async {
    final prefix = request.url.queryParameters['prefix'];
    if (prefix == null) {
      return Response.badRequest(
        body: jsonEncode({'error': 'prefix is required'}),
      );
    }
    final rows = await database.tenantMerkleRows(tenantId);
    final tree = MerkleService.buildTreeFromRows(
      tasks: rows['tasks']!,
      dependencies: rows['dependencies']!,
      resources: rows['resources']!,
      resetTimestamp: MerkleService.resetTimestampFromRows(
        rows['metadata'] ?? [],
      ),
    );
    final node = tree.getNode(prefix);
    return _json({
      'data': {
        'tenantId': tenantId,
        'prefix': prefix,
        'children':
            node?.children.map((key, value) => MapEntry(key, value.hash)) ?? {},
      },
    });
  }

  Future<Response> _merkleEntities(Request request, String tenantId) async {
    final prefix = request.url.queryParameters['prefix'];
    if (prefix == null) {
      return Response.badRequest(
        body: jsonEncode({'error': 'prefix is required'}),
      );
    }
    return _json({
      'data': {
        'tenantId': tenantId,
        'prefix': prefix,
        'entities': await database.tenantMerkleEntities(tenantId, prefix),
      },
    });
  }

  Future<Response> _genericTable(
    Request request,
    String schema,
    String table,
  ) => _list(request, '$schema.$table');

  Future<Response> _list(
    Request request,
    String tableKey, {
    Map<String, String> filters = const {},
  }) async {
    try {
      final queryFilters = <String, String>{...filters};
      for (final key in database.definition(tableKey).filterColumns.keys) {
        final value = request.url.queryParameters[key];
        if (value != null) queryFilters[key] = value;
      }
      final page = await database.listRows(
        tableKey,
        tenantId: request.url.queryParameters['tenantId'],
        filters: queryFilters,
        search: request.url.queryParameters['search'],
        includeDeleted: _includeDeleted(request),
        sort: request.url.queryParameters['sort'],
        limit: _intQuery(request, 'limit', 100),
        offset: _offsetQuery(request),
      );
      return _json(page.toJson());
    } on InspectorRequestException catch (error) {
      return Response.badRequest(body: jsonEncode({'error': error.message}));
    }
  }

  Future<Response> _one(
    Request request,
    String tableKey,
    Map<String, String> filters, {
    String? tenantId,
  }) async {
    try {
      final row = await database.getRow(
        tableKey,
        tenantId: tenantId,
        filters: filters,
      );
      if (row == null) return Response.notFound('Row not found');
      return _json({'data': row});
    } on InspectorRequestException catch (error) {
      return Response.badRequest(body: jsonEncode({'error': error.message}));
    }
  }

  static bool _includeDeleted(Request request) {
    final value = request.url.queryParameters['includeDeleted'];
    if (value == null) return true;
    return value.toLowerCase() != 'false' && value != '0';
  }

  static int _intQuery(Request request, String name, int fallback) {
    final value = int.tryParse(request.url.queryParameters[name] ?? '');
    return value ?? fallback;
  }

  static int _offsetQuery(Request request) {
    final offset = int.tryParse(request.url.queryParameters['offset'] ?? '');
    if (offset != null) return offset;
    final cursor = request.url.queryParameters['cursor'];
    if (cursor == null) return 0;
    try {
      return int.parse(utf8.decode(base64Url.decode(cursor)));
    } catch (_) {
      throw const InspectorRequestException('Invalid cursor');
    }
  }

  static Response _json(Object body) => Response.ok(
    jsonEncode(body),
    headers: {'Content-Type': 'application/json; charset=utf-8'},
  );
}
