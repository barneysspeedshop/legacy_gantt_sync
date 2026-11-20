import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';

class MerkleService {
  final CrdtService crdtService;

  MerkleService(this.crdtService);

  Future<MerkleTree> _getMerkleTree(String tenantId) async {
    final tasks = await crdtService.query(
      tenantId,
      'SELECT * FROM tasks WHERE tenant_id = ?',
      [tenantId],
    );
    final deps = await crdtService.query(
      tenantId,
      'SELECT * FROM dependencies WHERE tenant_id = ?',
      [tenantId],
    );
    final resources = await crdtService.query(
      tenantId,
      'SELECT * FROM resources WHERE tenant_id = ?',
      [tenantId],
    );

    final metadata = await crdtService.query(
      tenantId,
      'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ?',
      [tenantId],
    );

    return buildTreeFromRows(
      tasks: tasks,
      dependencies: deps,
      resources: resources,
      resetTimestamp: resetTimestampFromRows(metadata),
    );
  }

  /// Builds a Merkle tree from already-loaded rows.
  ///
  /// The local inspector uses this entry point so it can remain read-only
  /// while sharing the production hash implementation.
  static MerkleTree buildTreeFromRows({
    required List<Map<String, dynamic>> tasks,
    required List<Map<String, dynamic>> dependencies,
    required List<Map<String, dynamic>> resources,
    Hlc? resetTimestamp,
  }) {
    final items = <MapEntry<String, String>>[];
    for (final row in tasks) {
      final hlcStr = MerkleHashNormalizer.merkleHlcKey(
        CrdtService.recordTimestamp(row),
      );
      items.add(MapEntry(hlcStr, _hashTask(row)));
    }
    for (final row in dependencies) {
      final hlcStr = MerkleHashNormalizer.merkleHlcKey(
        CrdtService.recordTimestamp(row),
      );
      items.add(MapEntry(hlcStr, _hashDependency(row)));
    }
    for (final row in resources) {
      final hlcStr = MerkleHashNormalizer.merkleHlcKey(
        CrdtService.recordTimestamp(row),
      );
      items.add(MapEntry(hlcStr, _hashResource(row)));
    }
    if (resetTimestamp != null) {
      items.add(CRDTEngine.resetMerkleEntry(resetTimestamp));
    }
    return MerkleTree.build(items);
  }

  static Hlc? resetTimestampFromRows(List<Map<String, dynamic>> rows) {
    final value = rows.firstOrNull?['last_reset_at'];
    return value == null || value.toString().isEmpty
        ? null
        : Hlc.parse(value.toString());
  }

  /// Generates the Merkle Root hash for a given tenant.
  Future<String> getMerkleRoot(String tenantId) async {
    final tree = await _getMerkleTree(tenantId);
    return tree.root.hash;
  }

  /// Returns the children hashes of a specific Merkle Tree node prefix.
  Future<Map<String, String>> getMerkleNodeChildren(
    String tenantId,
    String prefix,
  ) async {
    final tree = await _getMerkleTree(tenantId);
    final node = tree.getNode(prefix);
    if (node == null) return {};

    return node.children.map((key, childNode) => MapEntry(key, childNode.hash));
  }

  /// Returns the raw entities inside a specific HLC prefix bucket, formatted as operations.
  /// Implements "Live-First" sorting: non-deleted items are sent before tombstones.
  Future<List<Map<String, dynamic>>> getEntitiesInPrefix(
    String tenantId,
    String prefix,
  ) async {
    final tasks =
        (await crdtService.query(
          tenantId,
          'SELECT * FROM tasks WHERE tenant_id = ?',
          [tenantId],
        )).where(
          (row) =>
              MerkleHashNormalizer.merkleMinutePrefix(
                CrdtService.recordTimestamp(row),
              ) ==
              prefix,
        );
    final deps =
        (await crdtService.query(
          tenantId,
          'SELECT * FROM dependencies WHERE tenant_id = ?',
          [tenantId],
        )).where(
          (row) =>
              MerkleHashNormalizer.merkleMinutePrefix(
                CrdtService.recordTimestamp(row),
              ) ==
              prefix,
        );
    final resources =
        (await crdtService.query(
          tenantId,
          'SELECT * FROM resources WHERE tenant_id = ?',
          [tenantId],
        )).where(
          (row) =>
              MerkleHashNormalizer.merkleMinutePrefix(
                CrdtService.recordTimestamp(row),
              ) ==
              prefix,
        );

    final List<Map<String, dynamic>> operations = [];
    final resetRows = await crdtService.query(
      tenantId,
      'SELECT last_reset_at FROM project_metadata WHERE tenant_id = ?',
      [tenantId],
    );
    final reset = resetTimestampFromRows(resetRows);
    if (reset != null &&
        MerkleHashNormalizer.merkleMinutePrefix(reset.toString()) == prefix) {
      operations.add({
        'type': 'RESET_DATA',
        'data': <String, dynamic>{},
        'timestamp': reset.toString(),
        'actorId': 'server-sync',
      });
    }

    for (final row in tasks) {
      operations.add(crdtService.formatTaskOperation(row));
    }

    for (final record in deps) {
      final op = crdtService.formatDependencyOperation(record);
      if (op != null) operations.add(op);
    }

    for (final record in resources) {
      operations.add(crdtService.formatResourceOperation(record));
    }

    // "Live-First" Sorting Logic:
    // We sort the operations list so that any operation that is a DELETION
    // (or represents a tombstone) comes after INSERTs/UPDATEs.
    operations.sort((a, b) {
      if (a['type'] == 'RESET_DATA') return b['type'] == 'RESET_DATA' ? 0 : -1;
      if (b['type'] == 'RESET_DATA') return 1;
      final isADelete = _isOperationADelete(a);
      final isBDelete = _isOperationADelete(b);

      if (isADelete && !isBDelete) return 1;
      if (!isADelete && isBDelete) return -1;
      return 0; // Maintain relative order for same types
    });

    return operations;
  }

  bool _isOperationADelete(Map<String, dynamic> op) {
    final type = op['type']?.toString().toUpperCase() ?? '';
    if (type.contains('DELETE')) return true;

    // Check for nested isDeleted flags in BATCH/INSERT/UPDATE
    final data = op['data'] as Map<String, dynamic>? ?? {};
    if (data['isDeleted'] == true ||
        data['is_deleted'] == true ||
        data['is_deleted'] == 1) {
      return true;
    }
    return false;
  }

  static String _hashTask(Map<String, dynamic> row) {
    final operation = CrdtService().formatTaskOperation(row);
    return ProtobufMapper.taskFromJson(
      operation['data'] as Map<String, dynamic>,
    ).contentHash;
  }

  static String _hashDependency(Map<String, dynamic> row) {
    final operation = CrdtService().formatDependencyOperation(row)!;
    final dependency = ProtobufMapper.dependencyFromJson(
      operation['data'] as Map<String, dynamic>,
    );
    if (operation['type'] == 'DELETE_DEPENDENCY') dependency.type = 'DELETE';
    return dependency.contentHash;
  }

  static String _hashResource(Map<String, dynamic> row) {
    final operation = CrdtService().formatResourceOperation(row);
    return ProtobufMapper.resourceFromJson(
      operation['data'] as Map<String, dynamic>,
    ).contentHash;
  }
}
