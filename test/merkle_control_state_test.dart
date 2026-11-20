import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';
import 'package:legacy_gantt_sync/server/services/crdt_service.dart';
import 'package:legacy_gantt_sync/server/services/merkle_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _CrdtService extends Mock implements CrdtService {}

void main() {
  const reset = Hlc(millis: 500, counter: 0, nodeId: 'fixture');
  late _CrdtService database;
  late MerkleService service;
  setUp(() {
    database = _CrdtService();
    service = MerkleService(database);
    when(() => database.query(any(), any(), any())).thenAnswer((
      invocation,
    ) async {
      final sql = invocation.positionalArguments[1] as String;
      return sql.contains('project_metadata')
          ? [
              {'last_reset_at': reset.toString()},
            ]
          : [];
    });
  });

  test('server empty-project root includes reset control state', () async {
    final root = await service.getMerkleRoot('tenant');
    expect(root, CRDTEngine().computeMerkleRoot([], resetTimestamp: reset));
    expect(root, isNot(CRDTEngine().computeMerkleRoot([])));
  });

  test(
    'reset leaf exports a standalone control operation for its minute',
    () async {
      final prefix = MerkleHashNormalizer.merkleMinutePrefix(reset.toString());
      final operations = await service.getEntitiesInPrefix('tenant', prefix);
      expect(operations, [
        {
          'type': 'RESET_DATA',
          'data': <String, dynamic>{},
          'timestamp': reset.toString(),
          'actorId': 'server-sync',
        },
      ]);
      expect(
        await service.getEntitiesInPrefix('tenant', '2099-01-01T00:00'),
        isEmpty,
      );
    },
  );
}
