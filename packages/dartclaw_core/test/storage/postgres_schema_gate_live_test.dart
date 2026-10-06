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
      final origin = await backend.query('''
        SELECT data_type, is_nullable FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'workflow_runs' AND column_name = 'origin_json'
      ''');
      expect(origin.single, {'data_type': 'text', 'is_nullable': 'YES'});
      for (final table in ['memory_chunks', 'conversation_chunks']) {
        final vector = await backend.query('''
        SELECT column_name, data_type, is_nullable FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = '$table' AND column_name = 'content_tsv'
      ''');
        expect(vector.single, {'column_name': 'content_tsv', 'data_type': 'tsvector', 'is_nullable': 'NO'});
        final gin = await backend.query('''
        SELECT indexdef FROM pg_indexes
        WHERE schemaname = current_schema() AND indexname = '${table}_content_tsv_idx'
      ''');
        expect(gin.single['indexdef'], contains('USING gin (content_tsv)'));
      }
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
                  'memory_chunks', 'conversation_chunks', 'dartclaw_schema'])
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

  test('missing conversation GIN index refuses without repair', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      await backend.execute('DROP INDEX conversation_chunks_content_tsv_idx');
      final before = await _searchCatalog(backend);
      final error = await _refusal(backend);
      expect(error.differences, contains('missing or mismatched index conversation_chunks_content_tsv_idx'));
      expect(await _searchCatalog(backend), before);
    });
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

  group('released 0.27 workflow run transition', () {
    test(
      'adds origin_json once, leaves the marker and every row untouched, and a second prepare writes nothing',
      () async {
        await withPostgresBackend((backend, _) async {
          await _prepareLegacyStore(backend, runIds: ['run-a', 'run-b']);
          final rowsBefore = await _legacyRunRows(backend);
          final marker = await backend.query('SELECT id, epoch FROM dartclaw_schema');

          await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);

          final column = await backend.query('''
          SELECT data_type, is_nullable FROM information_schema.columns
          WHERE table_schema = current_schema() AND table_name = 'workflow_runs' AND column_name = 'origin_json'
        ''');
          expect(column.single, {'data_type': 'text', 'is_nullable': 'YES'});
          expect(await backend.query('SELECT id, epoch FROM dartclaw_schema'), marker);
          expect(await _legacyRunRows(backend), rowsBefore);
          expect(await backend.query('SELECT id FROM workflow_runs WHERE origin_json IS NOT NULL'), isEmpty);

          final repeat = FailingDatabaseBackend(backend, failAt: 1);
          await PostgresSchemaGate.prepare(repeat, databaseIdentity: backend.databaseIdentity);
          expect(repeat.executeCount, 0);
          await PostgresSchemaGate.validateCurrent(backend, databaseIdentity: backend.databaseIdentity);
        });
      },
    );

    test('every other shape refuses and leaves the catalog unchanged', () async {
      final refusedShapes = <String, List<String>>{
        'legacy plus another missing column': ['ALTER TABLE workflow_runs DROP COLUMN workflow_worktree_json'],
        'legacy plus another missing table': ['DROP TABLE kg_facts'],
        'legacy plus a mismatched column': [
          'ALTER TABLE workflow_runs ALTER COLUMN error_message TYPE bigint USING NULL',
        ],
        'origin_json of a different type': ['ALTER TABLE workflow_runs ADD COLUMN origin_json bigint'],
        'origin_json that is not nullable text': [
          'ALTER TABLE workflow_runs ADD COLUMN origin_json TEXT NOT NULL DEFAULT \'x\'',
        ],
        'absent marker': ['DROP TABLE dartclaw_schema'],
        'empty marker': ['DELETE FROM dartclaw_schema'],
        'non-1 marker': ['UPDATE dartclaw_schema SET epoch = 2'],
        'duplicated marker': [
          'ALTER TABLE dartclaw_schema DROP CONSTRAINT dartclaw_schema_pkey',
          'ALTER TABLE dartclaw_schema DROP CONSTRAINT dartclaw_schema_id_check',
          'INSERT INTO dartclaw_schema (id, epoch) VALUES (1, 1)',
        ],
        'malformed marker': ['ALTER TABLE dartclaw_schema ALTER COLUMN epoch TYPE text'],
      };
      for (final entry in refusedShapes.entries) {
        await withPostgresBackend((backend, _) async {
          await _prepareLegacyStore(backend, runIds: ['run-a']);
          for (final sql in entry.value) {
            await backend.execute(sql);
          }
          final before = await _columnCatalog(backend);
          final error = await _refusal(backend);
          expect(error.action, contains('reset/recreate'), reason: entry.key);
          expect(await _columnCatalog(backend), before, reason: entry.key);
        });
      }
    });

    test('validateCurrent refuses the exact legacy shape without writing and names dartclaw serve', () async {
      await withPostgresBackend((backend, _) async {
        await _prepareLegacyStore(backend, runIds: ['run-a']);
        final before = await _columnCatalog(backend);
        final recording = FailingDatabaseBackend(backend, failAt: 1);

        final error = await _validateRefusal(recording);

        expect(error.differences, ['missing column workflow_runs.origin_json']);
        expect(error.action, contains('dartclaw serve'));
        expect(error.action, isNot(contains('reset')));
        expect(error.action, isNot(contains('recreate')));
        expect(recording.executeCount, 0);
        expect(await _columnCatalog(backend), before);
      });
    });

    test('a failed statement at any position rolls the transition back and a retry converges', () async {
      var statementCount = 0;
      await withPostgresBackend((backend, _) async {
        await _prepareLegacyStore(backend, runIds: ['run-a']);
        final recording = FailingDatabaseBackend(backend, failAt: 1000);
        await PostgresSchemaGate.prepare(recording, databaseIdentity: backend.databaseIdentity);
        statementCount = recording.executeCount;
      });
      expect(statementCount, greaterThan(0));

      for (var failAt = 1; failAt <= statementCount; failAt++) {
        await withPostgresBackend((backend, _) async {
          await _prepareLegacyStore(backend, runIds: ['run-a']);
          final before = await _columnCatalog(backend);
          final failing = FailingDatabaseBackend(backend, failAt: failAt);

          await expectLater(
            () => PostgresSchemaGate.prepare(failing, databaseIdentity: backend.databaseIdentity),
            throwsA(isA<StateError>()),
            reason: 'failure at statement $failAt',
          );

          expect(await _columnCatalog(backend), before, reason: 'failure at statement $failAt');
          expect(await backend.query('SELECT epoch FROM dartclaw_schema'), [
            {'epoch': 1},
          ]);
          failing.disableFailure();
          await PostgresSchemaGate.prepare(failing, databaseIdentity: backend.databaseIdentity);
          await PostgresSchemaGate.validateCurrent(backend, databaseIdentity: backend.databaseIdentity);
        });
      }
    });

    test('a failure while re-validating after the ALTER rolls the column back', () async {
      await withPostgresBackend((backend, _) async {
        await _prepareLegacyStore(backend, runIds: ['run-a']);
        final before = await _columnCatalog(backend);
        final failing = FailingDatabaseBackend(backend, failAt: 1000, failQueryAfterExecute: true);

        await expectLater(
          () => PostgresSchemaGate.prepare(failing, databaseIdentity: backend.databaseIdentity),
          throwsA(isA<StateError>()),
        );

        expect(await _columnCatalog(backend), before);
        failing.disableFailure();
        await PostgresSchemaGate.prepare(failing, databaseIdentity: backend.databaseIdentity);
        await PostgresSchemaGate.validateCurrent(backend, databaseIdentity: backend.databaseIdentity);
      });
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
  SELECT 'column' AS kind, table_name || '.' || column_name AS name, data_type || ':' || is_nullable AS definition
  FROM information_schema.columns WHERE table_schema = current_schema() AND table_name IN ('memory_chunks', 'conversation_chunks')
  UNION ALL
  SELECT 'index', indexname, indexdef FROM pg_indexes
  WHERE schemaname = current_schema() AND tablename IN ('memory_chunks', 'conversation_chunks')
  ORDER BY kind, name
''');

Future<SchemaIncompatibleException> _validateRefusal(DatabaseBackend backend) async {
  try {
    await PostgresSchemaGate.validateCurrent(backend, databaseIdentity: 'test database');
    throw StateError('Expected incompatible schema');
  } on SchemaIncompatibleException catch (error) {
    return error;
  }
}

/// Builds the released 0.27 shape: the current schema minus `workflow_runs.origin_json`, holding runs.
Future<void> _prepareLegacyStore(PostgresBackend backend, {required List<String> runIds}) async {
  await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
  await backend.execute('ALTER TABLE workflow_runs DROP COLUMN origin_json');
  for (final id in runIds) {
    await backend.execute(
      '''
      INSERT INTO workflow_runs (id, definition_name, status, started_at, updated_at, execution_cursor_json)
      VALUES (?, 'legacy-workflow', 'completed', '2026-01-01T00:00:00.000Z', '2026-01-01T00:05:00.000Z', NULL)
      ''',
      [id],
    );
  }
}

Future<List<Map<String, Object?>>> _legacyRunRows(PostgresBackend backend) => backend.query('''
  SELECT id, definition_name, status, context_json, variables_json, started_at, updated_at, completed_at,
         error_message, total_tokens, current_step_index, definition_json, execution_cursor_json,
         workflow_worktree_json
  FROM workflow_runs ORDER BY id
  ''');

Future<List<Map<String, Object?>>> _columnCatalog(PostgresBackend backend) => backend.query('''
  SELECT table_name, column_name, data_type, is_nullable, column_default
  FROM information_schema.columns WHERE table_schema = current_schema()
  ORDER BY table_name, column_name
''');
