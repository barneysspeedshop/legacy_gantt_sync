import 'package:postgres/postgres.dart';
import 'package:postgres_crdt/postgres_crdt.dart' as pg show Hlc;

/// Repairs the ISO-only bookkeeping clocks written by the old bulk task handler.
/// Entity fields and valid CRDT clocks are untouched. Each bounded batch keeps
/// the normal tenant session boundary; no RLS policy is disabled for migration.
Future<int> repairLegacyModifiedClocks(Connection connection) async {
  final columns = await connection.execute('''
    SELECT column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'tasks'
      AND column_name IN ('modified', 'hlc', 'node_id', 'tenant_id', 'id')
  ''');
  if (columns.length != 5) return 0;

  final registries = await connection.execute('''
    SELECT to_regclass('auth.tenants')::text AS tenants,
           to_regclass('public.project_metadata')::text AS metadata
  ''');
  final sources = <String>[
    if (registries.first[0] != null) 'SELECT id AS tenant_id FROM auth.tenants',
    if (registries.first[1] != null)
      'SELECT tenant_id FROM public.project_metadata',
  ];
  if (sources.isEmpty) return 0;
  final tenants = await connection.execute(sources.join(' UNION '));
  var repaired = 0;
  for (final tenant in tenants) {
    while (true) {
      final count = await connection.runTx((transaction) async {
        await transaction.execute(
          Sql.named("SELECT set_config('app.current_tenant', @tenant, true)"),
          parameters: {'tenant': tenant[0]},
        );
        final rows = await transaction.execute(
          Sql.named(r'''
            SELECT id, modified, hlc, node_id FROM public.tasks
            WHERE tenant_id = @tenant AND modified ~ @iso
            ORDER BY id LIMIT 500 FOR UPDATE
          '''),
          parameters: {
            'tenant': tenant[0],
            'iso': r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3}(\d{3})?)?Z?$',
          },
        );
        for (final row in rows) {
          final modified = row[1] as String;
          final date = DateTime.parse(modified).toUtc();
          String? replacement;
          try {
            final original = pg.Hlc.parse(row[2] as String);
            if (original.dateTime.isAtSameMomentAs(date)) {
              replacement = original.toString();
            }
          } catch (_) {
            // The ISO timestamp can still recover the bookkeeping clock.
          }
          replacement ??= pg.Hlc.fromDate(
            date,
            row[3] as String? ?? 'legacy-repair',
          ).toString();
          await transaction.execute(
            Sql.named(
              'UPDATE public.tasks SET modified = @clock WHERE tenant_id = @tenant AND id = @id AND modified = @original',
            ),
            parameters: {
              'clock': replacement,
              'tenant': tenant[0],
              'id': row[0],
              'original': modified,
            },
          );
        }
        return rows.length;
      });
      repaired += count;
      if (count < 500) break;
    }
  }
  return repaired;
}
