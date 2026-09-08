@Tags(['integration'])
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'failing_database_backend.dart';
import 'postgres_live_support.dart';

void main() {
  test('fresh bootstrap is exact and current reopen is read-only', () async {
    await withPostgresBackend((backend, _) async {
      final recording = FailingDatabaseBackend(backend, failAt: 1000);
      await PostgresSchemaGate.prepare(recording, databaseIdentity: backend.databaseIdentity);
      expect(recording.executeCount, greaterThan(20));

      final tables = await backend.query('''
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = current_schema()
      ''');
      final names = tables.map((row) => row['table_name']).toSet();
      for (final table in [...SchemaIdentity.tasks.tables, ...SchemaIdentity.search.tables]) {
        expect(names, contains(table.name));
      }
      expect((await backend.query('SELECT id, epoch FROM dartclaw_schema')).single, {'id': 1, 'epoch': 1});
      final vector = await backend.query('''
        SELECT column_name, data_type, is_nullable FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'memory_chunks' AND column_name = 'content_tsv'
      ''');
      expect(vector.single, {'column_name': 'content_tsv', 'data_type': 'tsvector', 'is_nullable': 'NO'});
      final gin = await backend.query('''
        SELECT indexdef FROM pg_indexes
        WHERE schemaname = current_schema() AND indexname = 'memory_chunks_content_tsv_idx'
      ''');
      expect(gin.single['indexdef'], contains('USING gin (content_tsv)'));
      expect(
        await backend.query('''
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'kg_facts' AND data_type = 'tsvector'
      '''),
        isEmpty,
      );
      final kgIndexes = await backend.query('''
        SELECT indexname FROM pg_indexes
        WHERE schemaname = current_schema() AND tablename = 'kg_facts' ORDER BY indexname
      ''');
      expect(kgIndexes.map((row) => row['indexname']), ['kg_facts_lookup', 'kg_facts_pkey']);

      final refusingWrites = FailingDatabaseBackend(backend, failAt: 1);
      await PostgresSchemaGate.prepare(refusingWrites, databaseIdentity: backend.databaseIdentity);
      expect(refusingWrites.executeCount, 0);
    });
  });

  test('every bootstrap prefix rolls back to an object-free catalog', () async {
    var statementCount = 0;
    await withPostgresBackend((backend, _) async {
      final recording = FailingDatabaseBackend(backend, failAt: 1000);
      await PostgresSchemaGate.prepare(recording, databaseIdentity: backend.databaseIdentity);
      statementCount = recording.executeCount;
    });
    for (var failAt = 1; failAt <= statementCount; failAt++) {
      await withPostgresBackend((backend, _) async {
        final failing = FailingDatabaseBackend(backend, failAt: failAt);
        await expectLater(
          () => PostgresSchemaGate.prepare(failing, databaseIdentity: backend.databaseIdentity),
          throwsA(isA<StateError>()),
        );
        final owned = await backend.query('''
          SELECT table_name FROM information_schema.tables
          WHERE table_schema = current_schema() AND table_name LIKE ANY (
            ARRAY['tasks', 'goals', 'agent_executions', 'workflow_%', 'task_%', 'turns', 'kg_facts',
                  'memory_chunks', 'dartclaw_schema'])
        ''');
        expect(owned, isEmpty, reason: 'failure at statement $failAt');
        failing.disableFailure();
        await PostgresSchemaGate.prepare(failing, databaseIdentity: backend.databaseIdentity);
      });
    }
  });

  test('missing or incompatible memory vector objects refuse without repair', () async {
    for (final statements in [
      ['ALTER TABLE memory_chunks DROP COLUMN content_tsv CASCADE'],
      ['ALTER TABLE memory_chunks ALTER COLUMN content_tsv DROP NOT NULL'],
      ['DROP INDEX memory_chunks_content_tsv_idx'],
      [
        'DROP INDEX memory_chunks_content_tsv_idx',
        'CREATE INDEX memory_chunks_content_tsv_idx ON memory_chunks (content_tsv)',
      ],
      [
        'DROP INDEX memory_chunks_content_tsv_idx',
        "CREATE INDEX memory_chunks_content_tsv_idx ON memory_chunks USING gin (content_tsv) WHERE user_id = 'owner'",
      ],
    ]) {
      await withPostgresBackend((backend, _) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        for (final sql in statements) {
          await backend.execute(sql);
        }
        final before = await _searchCatalog(backend);
        expect(await _refusal(backend), isA<SchemaIncompatibleException>());
        expect(await _searchCatalog(backend), before);
      });
    }
  });

  test('incompatible marker and structure refuse without mutation', () async {
    await withPostgresBackend((backend, _) async {
      await backend.execute('CREATE TABLE tasks (id text PRIMARY KEY)');
      final before = await _catalog(backend);
      final error = await _refusal(backend);
      expect(error.foundEpoch, 'absent');
      expect(error.differences, contains('missing table agent_executions'));
      expect('$error', contains(backend.databaseIdentity));
      expect(await _catalog(backend), before);
    });

    for (final marker in <String>[
      'CREATE TABLE dartclaw_schema (id bigint PRIMARY KEY, epoch bigint NOT NULL)',
      'CREATE TABLE dartclaw_schema (id bigint PRIMARY KEY, epoch text NOT NULL)',
    ]) {
      await withPostgresBackend((backend, _) async {
        await backend.execute(marker);
        await backend.execute("INSERT INTO dartclaw_schema (id, epoch) VALUES (1, '0')");
        expect(await _refusal(backend), isA<SchemaIncompatibleException>());
      });
    }
  });

  test('unrelated non-empty namespace refuses without mutation', () async {
    await withPostgresBackend((backend, _) async {
      await backend.execute('CREATE TABLE unrelated_table (id bigint PRIMARY KEY)');
      final before = await _catalog(backend);
      final error = await _refusal(backend);
      expect(error.foundEpoch, 'absent');
      expect(error.differences, contains('missing table tasks'));
      expect(await _catalog(backend), before);
    });
  });
}

Future<SchemaIncompatibleException> _refusal(PostgresBackend backend) async {
  try {
    await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
    throw StateError('Expected incompatible schema');
  } on SchemaIncompatibleException catch (error) {
    return error;
  }
}

Future<List<Map<String, Object?>>> _catalog(PostgresBackend backend) => backend.query('''
  SELECT table_name FROM information_schema.tables
  WHERE table_schema = current_schema()
  ORDER BY table_name
''');

Future<List<Map<String, Object?>>> _searchCatalog(PostgresBackend backend) => backend.query('''
  SELECT 'column' AS kind, column_name AS name, data_type || ':' || is_nullable AS definition
  FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'memory_chunks'
  UNION ALL
  SELECT 'index', indexname, indexdef FROM pg_indexes
  WHERE schemaname = current_schema() AND tablename = 'memory_chunks'
  ORDER BY kind, name
''');
