@Tags(['integration'])
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'failing_database_backend.dart';
import 'postgres_live_support.dart';

void main() {
  test('restricted runtime role preflights admin-provisioned public pgvector', () async {
    await withPostgresBackend((backend, namespace) async {
      final role = (await backend.query('''
        SELECT rolsuper, rolcreatedb, rolcreaterole
        FROM pg_catalog.pg_roles
        WHERE rolname = current_user
      ''')).single;
      expect(role, {'rolsuper': 0, 'rolcreatedb': 0, 'rolcreaterole': 0});
      await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: backend.databaseIdentity);
      final extension = (await backend.query('''
        SELECT namespace.nspname AS extension_schema,
               owner.rolname = current_user AS runtime_owns_extension
        FROM pg_catalog.pg_extension extension
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid = extension.extnamespace
        JOIN pg_catalog.pg_roles owner ON owner.oid = extension.extowner
        WHERE extension.extname = 'vector'
      ''')).single;
      expect(extension, {'extension_schema': 'public', 'runtime_owns_extension': 0});
      expect(
        (await backend.query("SELECT current_schema() AS app_schema, current_setting('search_path') AS search_path"))
            .single,
        {'app_schema': namespace, 'search_path': namespace},
      );
      final before = await _catalog(backend);
      await expectLater(
        PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: backend.databaseIdentity),
        throwsA(isA<SchemaIncompatibleException>()),
      );
      expect(await _catalog(backend), before);
    });
  });

  test('absent vector projection bootstraps exactly and current reopen is read-only', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: backend.databaseIdentity);
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      await _seedAuthoritativeRow(backend);
      final authoritative = await _authoritativeState(backend);
      expect(await _vectorCatalog(backend), isEmpty);

      await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: backend.databaseIdentity);
      final vectors = await _vectorCatalog(backend);
      expect(vectors.where((row) => row['kind'] == 'table').map((row) => row['name']), [
        'conversation_vectors',
        'memory_vectors',
      ]);
      expect(vectors.where((row) => row['kind'] == 'embedding').map((row) => row['definition']), [
        'public.vector',
        'public.vector',
      ]);
      expect(vectors.where((row) => row['kind'] == 'index').map((row) => row['name']), [
        'conversation_vectors_lookup_idx',
        'memory_vectors_lookup_idx',
      ]);
      expect(await _authoritativeState(backend), authoritative);

      final recording = RecordingDatabaseBackend(backend);
      await PostgresSchemaGate.prepareVectorProjection(recording, databaseIdentity: backend.databaseIdentity);
      expect(recording.transactionCount, 0);
      expect(recording.executeCount, 0);
      expect(recording.prepareCount, 0);
      expect(await _vectorCatalog(backend), vectors);
      expect(await _authoritativeState(backend), authoritative);
    });
  });

  test('partial vector projection refuses without repairing authoritative state', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: backend.databaseIdentity);
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      await _seedAuthoritativeRow(backend);
      await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: backend.databaseIdentity);
      await backend.execute('DROP TABLE conversation_vectors');
      final authoritative = await _authoritativeState(backend);
      final partial = await _vectorCatalog(backend);

      final error = await _projectionRefusal(backend);
      expect(error.differences, contains('missing table conversation_vectors'));
      expect('$error', contains('only memory_vectors and conversation_vectors'));
      expect(await _vectorCatalog(backend), partial);
      expect(await _authoritativeState(backend), authoritative);
    });
  });

  test('failed vector bootstrap rolls back all derived objects and preserves authority', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: backend.databaseIdentity);
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      await _seedAuthoritativeRow(backend);
      final authoritative = await _authoritativeState(backend);
      final failing = FailingDatabaseBackend(backend, failAt: 3);

      await expectLater(
        PostgresSchemaGate.prepareVectorProjection(failing, databaseIdentity: backend.databaseIdentity),
        throwsStateError,
      );
      expect(await _vectorCatalog(backend), isEmpty);
      expect(await _authoritativeState(backend), authoritative);
    });
  });
}

Future<void> _seedAuthoritativeRow(PostgresBackend backend) => backend.execute(
  '''INSERT INTO goals (id, title, mission, created_at)
     VALUES (?, ?, ?, ?)''',
  const ['preserved-goal', 'Preserved', 'Keep authoritative data', '2026-01-01T00:00:00Z'],
);

Future<SchemaIncompatibleException> _projectionRefusal(PostgresBackend backend) async {
  try {
    await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: backend.databaseIdentity);
    throw StateError('Expected incompatible vector projection');
  } on SchemaIncompatibleException catch (error) {
    return error;
  }
}

Future<Map<String, Object?>> _authoritativeState(PostgresBackend backend) async => {
  'tables': await backend.query('''
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = current_schema()
      AND table_name NOT IN ('memory_vectors', 'conversation_vectors')
    ORDER BY table_name
  '''),
  'marker': await backend.query('SELECT id, epoch FROM dartclaw_schema ORDER BY id'),
  'goals': await backend.query('SELECT id, title, mission, created_at FROM goals ORDER BY id'),
};

Future<List<Map<String, Object?>>> _catalog(PostgresBackend backend) => backend.query('''
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema()
      ORDER BY table_name
    ''');

Future<List<Map<String, Object?>>> _vectorCatalog(PostgresBackend backend) => backend.query('''
      SELECT 'table' AS kind, table_name AS name, '' AS definition
      FROM information_schema.tables
      WHERE table_schema = current_schema()
        AND table_name IN ('memory_vectors', 'conversation_vectors')
      UNION ALL
      SELECT 'embedding', table_name,
             udt_schema || '.' || udt_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name IN ('memory_vectors', 'conversation_vectors')
        AND column_name = 'embedding'
      UNION ALL
      SELECT 'index', indexname, indexdef
      FROM pg_indexes
      WHERE schemaname = current_schema()
        AND tablename IN ('memory_vectors', 'conversation_vectors')
        AND indexname IN (
          'memory_vectors_lookup_idx',
          'conversation_vectors_lookup_idx'
        )
      ORDER BY kind, name
    ''');
