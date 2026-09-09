import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('PostgreSQL vector extension preflight', () {
    test('requires the public extension and type without mutating the database', () async {
      for (final availability in [
        (extension: false, type: false),
        (extension: false, type: true),
        (extension: true, type: false),
      ]) {
        final backend = PostgresVectorSchemaTestBackend.current(
          extensionAvailable: availability.extension,
          typeAvailable: availability.type,
        );
        await expectLater(
          PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: 'db.example:5432/app'),
          throwsA(
            isA<SchemaIncompatibleException>()
                .having((error) => error.action, 'action', contains('CREATE EXTENSION vector WITH SCHEMA public'))
                .having((error) => error.toString(), 'safe identity', isNot(contains('credential'))),
          ),
        );
        expect(backend.executed, isEmpty);
        expect(backend.transactions, 0);
      }
    });

    test('proves qualified cast, dimension, norm, and cosine capabilities', () async {
      final backend = PostgresVectorSchemaTestBackend.current();
      await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: 'db.example:5432/app');

      final capability = backend.queries.singleWhere((call) => call.sql.contains('CAST(CAST'));
      expect(
        capability.sql,
        allOf(contains('public.vector'), contains('public.vector_dims'), contains('public.l2_norm')),
      );
      expect(capability.sql, contains('OPERATOR(public.<=>)'));
      expect(capability.parameters, everyElement(anyOf('[1,0]', '[1.0,0.0]')));
      expect(backend.executed, isEmpty);
    });

    test('turns inaccessible capabilities into content-free administrator guidance', () async {
      final backend = PostgresVectorSchemaTestBackend.current(failCapability: true);
      await expectLater(
        PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: 'db.example:5432/app'),
        throwsA(
          isA<SchemaIncompatibleException>()
              .having((error) => error.action, 'action', contains('database administrator'))
              .having((error) => error.toString(), 'content', isNot(contains('driver-secret'))),
        ),
      );
    });

    test('does not translate programming errors into extension guidance', () async {
      final backend = PostgresVectorSchemaTestBackend.current(programmingFailure: true);
      await expectLater(
        PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: 'db.example:5432/app'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', 'programming sentinel')),
      );
    });
  });

  group('PostgreSQL vector projection schema', () {
    test('lexical-only preparation never queries or creates pgvector objects', () async {
      final backend = PostgresVectorSchemaTestBackend.empty();
      await PostgresSchemaGate.prepare(backend, databaseIdentity: 'db.example:5432/app');

      expect(
        backend.queries.every((call) => !call.sql.contains('pg_extension') && !call.sql.contains('public.vector')),
        isTrue,
      );
      expect(backend.executed.every((sql) => !sql.contains('public.vector') && !sql.contains('_vectors')), isTrue);
    });

    test('validates authoritative state first and bootstraps both tables atomically', () async {
      final backend = PostgresVectorSchemaTestBackend.current();
      await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: 'db.example:5432/app');

      expect(backend.transactions, 1);
      expect(backend.relations, containsAll(['memory_vectors', 'conversation_vectors']));
      expect(backend.executed.where((sql) => sql.startsWith('CREATE TABLE')).length, 2);
      expect(backend.executed.join('\n'), allOf(contains('public.vector'), isNot(contains('bytea'))));

      final writes = backend.executed.length;
      await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: 'db.example:5432/app');
      expect(backend.executed.length, writes);
    });

    test('refuses partial and incompatible projections with derived-only recovery', () async {
      final orphanedIndex = PostgresVectorSchemaTestBackend.current(vectorIndexes: const {'memory_vectors_lookup_idx'});
      for (final backend in [
        orphanedIndex,
        PostgresVectorSchemaTestBackend.current(vectorTables: const {'memory_vectors'}),
        PostgresVectorSchemaTestBackend.current(
          vectorTables: const {'memory_vectors', 'conversation_vectors'},
          vectorIndexes: const {'memory_vectors_lookup_idx', 'conversation_vectors_lookup_idx'},
          mismatchedVectorColumn: true,
        ),
      ]) {
        await expectLater(
          PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: 'db.example:5432/app'),
          throwsA(
            isA<SchemaIncompatibleException>()
                .having((error) => error.action, 'action', contains('memory_vectors and conversation_vectors'))
                .having((error) => error.action, 'authoritative isolation', isNot(contains('database'))),
          ),
        );
        expect(backend.transactions, 0);
      }
    });

    test('refuses both vector tables when their explicit lookup indexes are absent', () async {
      final backend = PostgresVectorSchemaTestBackend.current(
        vectorTables: const {'memory_vectors', 'conversation_vectors'},
      );

      await expectLater(
        PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: 'db.example:5432/app'),
        throwsA(
          isA<SchemaIncompatibleException>().having(
            (error) => error.differences,
            'differences',
            containsAll(['missing index memory_vectors_lookup_idx', 'missing index conversation_vectors_lookup_idx']),
          ),
        ),
      );
      expect(backend.transactions, 0);
    });

    test('refuses an absent authoritative namespace before creating vector tables', () async {
      final backend = PostgresVectorSchemaTestBackend.empty();
      await expectLater(
        PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: 'db.example:5432/app'),
        throwsA(isA<SchemaIncompatibleException>()),
      );
      expect(backend.executed, isEmpty);
      expect(backend.transactions, 0);
    });

    test('failed vector bootstrap rolls back every optional object', () async {
      final backend = PostgresVectorSchemaTestBackend.current(failVectorExecuteAt: 3);
      await expectLater(
        PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: 'db.example:5432/app'),
        throwsStateError,
      );
      expect(backend.relations, isNot(anyOf(contains('memory_vectors'), contains('conversation_vectors'))));
      expect(backend.vectorIndexes, isEmpty);
      expect(backend.authoritativeRows, 7);
    });
  });
}
