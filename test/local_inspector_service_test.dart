import 'package:legacy_gantt_sync/local_inspector/inspector_service.dart';
import 'package:test/test.dart';

void main() {
  group('Inspector table registry', () {
    test('covers every application table', () {
      expect(
        inspectorTableDefinitions.keys,
        containsAll(<String>[
          'auth.tenants',
          'auth.users',
          'auth.refresh_tokens',
          'public.tasks',
          'public.dependencies',
          'public.resources',
          'public.project_metadata',
          'public.licenses',
        ]),
      );
      expect(inspectorTableDefinitions, hasLength(8));
    });

    test('marks tenant tables and sensitive columns', () {
      expect(inspectorTableDefinitions['public.tasks']!.tenantScoped, isTrue);
      expect(
        inspectorTableDefinitions['auth.users']!.redactedColumns,
        contains('password_hash'),
      );
      expect(
        inspectorTableDefinitions['auth.refresh_tokens']!.redactedColumns,
        contains('token_hash'),
      );
      expect(
        inspectorTableDefinitions['public.licenses']!.redactedColumns,
        contains('license_key'),
      );
    });

    test('quotes only registered database identifiers', () {
      final definition = inspectorTableDefinitions['public.tasks']!;
      expect(definition.quotedName, equals('"public"."tasks"'));
    });

    test('rejects unknown tables', () {
      final database = InspectorDatabase(() async {
        throw StateError('Connection should not be opened');
      });

      expect(
        () => database.definition('public.unknown'),
        throwsA(isA<InspectorRequestException>()),
      );
    });
  });
}
