@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'postgres_live_support.dart';

void main() {
  final root = _workspaceRoot();
  final tool = File('${root.path}/dev/tools/migrate_sqlite_to_postgres.py');
  final fixture = File('${root.path}/dev/testing/fixtures/postgres_migration/dartclaw-v0.26.1.db');
  final wrongFixture = File('${root.path}/dev/testing/fixtures/postgres_migration/dartclaw-wrong-shape.db');
  final sentinel = File('${root.path}/dev/testing/fixtures/postgres_migration/canonical-files-sentinel.txt');
  final proof = jsonDecode(
    File('${root.path}/dev/testing/fixtures/postgres_migration/fixture-proof.json').readAsStringSync(),
  ) as Map<String, Object?>;

  group('bounded SQLite migration', () {
    test('preserves all authoritative values, relationships, identities, and source files', () async {
      await withPostgresBackend((backend, namespace) async {
        expect(await _sha256(fixture), proof['fixture_sha256']);
        expect(await _sha256(wrongFixture), proof['wrong_shape_sha256']);
        expect(
          await _sha256(File('${root.path}/dev/tools/migrate_sqlite_v0_26_1_manifest.json')),
          proof['manifest_sha256'],
        );
        expect(await _sha256(sentinel), proof['canonical_sentinel_sha256']);
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        final temp = await Directory.systemTemp.createTemp('dartclaw-migration-success-');
        addTearDown(() => temp.delete(recursive: true));
        final snapshot = await fixture.copy('${temp.path}/snapshot.db');
        final canonical = await sentinel.copy('${temp.path}/MEMORY.md');
        final sourceHash = await _sha256(snapshot);
        final canonicalHash = await _sha256(canonical);

        final result = await _runMigration(tool, snapshot, namespace);
        expect(result.exitCode, 0, reason: _safeResult(result));
        expect(result.stdout, contains('Migration completed.'));
        _expectRedacted(result);
        expect(await _sha256(snapshot), sourceHash);
        expect(await _sha256(canonical), canonicalHash);

        final expectedCounts = (proof['table_counts'] as Map<String, Object?>).cast<String, num>();
        for (final entry in expectedCounts.entries) {
          final rows = await backend.query('SELECT count(*) AS count FROM "${entry.key}"');
          expect(rows.single['count'], entry.value);
        }
        final preservation = await backend.query(
          '''
          SELECT
            (SELECT description = ? FROM tasks WHERE id = 'task-1') AS structural_text,
            (SELECT created_by = ? AND worktree_json IS NULL FROM tasks WHERE id = 'task-1') AS principal_and_null,
            (SELECT step_index = 4 AND map_iteration_index = 2 FROM workflow_step_executions
              WHERE task_id = 'task-1') AS ordering_fields,
            (SELECT owner = ? AND valid_to IS NULL FROM kg_facts WHERE id = 7) AS knowledge_owner,
            NOT EXISTS (SELECT 1 FROM memory_chunks) AND
              NOT EXISTS (SELECT 1 FROM conversation_chunks) AS derived_empty
          ''',
          ["line one\n\\.\n'); DROP TABLE tasks; --", 'agent:research/å', 'agent:research/å'],
        );
        expect(preservation.single.values, everyElement(1));
        final identity = await backend.query("SELECT nextval(pg_get_serial_sequence('kg_facts', 'id')) AS next_id");
        expect(identity.single['next_id'], proof['next_kg_fact_id']);
      });
    });

    test('refuses unsupported and ambiguous sources before target writes', () async {
      await withPostgresBackend((backend, namespace) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        final wrong = await _runMigration(tool, wrongFixture, namespace);
        expect(wrong.exitCode, 2);
        expect(wrong.stderr, contains('[source-shape]'));
        _expectRedacted(wrong);

        final temp = await Directory.systemTemp.createTemp('dartclaw-migration-ambiguous-');
        addTearDown(() => temp.delete(recursive: true));
        final missing = await _runMigration(tool, File('${temp.path}/missing.db'), namespace);
        expect(missing.exitCode, 2);
        expect(missing.stderr, contains('[source-unreadable]'));
        final snapshot = await fixture.copy('${temp.path}/snapshot.db');
        await File('${snapshot.path}-wal').writeAsBytes([1]);
        final ambiguous = await _runMigration(tool, snapshot, namespace);
        expect(ambiguous.exitCode, 2);
        expect(ambiguous.stderr, contains('[source-ambiguous]'));
        expect(await _allAuthoritativeRows(backend), 0);
      });
    });

    test('refuses incompatible, populated, repeated, active, and concurrently mutated targets', () async {
      await withPostgresBackend((backend, namespace) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        await backend.execute('ALTER TABLE tasks ALTER COLUMN title DROP NOT NULL');
        final incompatible = await _runMigration(tool, fixture, namespace);
        expect(incompatible.exitCode, 2);
        expect(incompatible.stderr, contains('[target-schema]'));
      });

      await withPostgresBackend((backend, namespace) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        await backend.execute('INSERT INTO workflow_run_migrations (name, applied_at) VALUES (?, ?)', [
          'already-present',
          '2026-09-01T00:00:00Z',
        ]);
        final populated = await _runMigration(tool, fixture, namespace);
        expect(populated.exitCode, 2);
        expect(populated.stderr, contains('[target-populated]'));
      });

      await withPostgresBackend((backend, namespace) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        expect((await _runMigration(tool, fixture, namespace)).exitCode, 0);
        final repeated = await _runMigration(tool, fixture, namespace);
        expect(repeated.exitCode, 2);
        expect(repeated.stderr, contains('[target-populated]'));
      });

      await withPostgresBackend((backend, namespace) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        final interlock = PostgresInterlock();
        await interlock.acquire(backend: backend, onFatalLoss: (_) {});
        try {
          final active = await _runMigration(tool, fixture, namespace);
          expect(active.exitCode, 2);
          expect(active.stderr, contains('[target-active]'));
        } finally {
          await interlock.release();
        }
      });

      await withPostgresBackend((backend, namespace) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        await backend.transaction((tx) async {
          await tx.execute('INSERT INTO workflow_run_migrations (name, applied_at) VALUES (?, ?)', [
            'concurrent',
            '2026-09-01T00:00:00Z',
          ]);
          final concurrent = await _runMigration(tool, fixture, namespace);
          expect(concurrent.exitCode, 2);
          expect(concurrent.stderr, contains('[target-busy]'));
        });
      });
    });

    test('rolls back post-write and verification failures without changing the source', () async {
      for (final fault in ['after-writes', 'verification']) {
        await withPostgresBackend((backend, namespace) async {
          await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
          final before = await _sha256(fixture);
          final result = await _runMigration(tool, fixture, namespace, fault: fault);
          expect(result.exitCode, 2);
          expect(result.stderr, contains(fault == 'after-writes' ? '[fault]' : '[verification]'));
          _expectRedacted(result);
          expect(await _allAuthoritativeRows(backend), 0);
          expect(await _sha256(fixture), before);
          final identity = await backend.query(
            'SELECT last_value FROM pg_sequences WHERE schemaname=current_schema() '
            "AND sequencename='kg_facts_id_seq'",
          );
          expect(identity.single['last_value'], isNull);
        });
      }
    });
  });
}

Directory _workspaceRoot() {
  var candidate = Directory.current.absolute;
  while (candidate.parent.path != candidate.path) {
    if (File('${candidate.path}/dev/tools/migrate_sqlite_to_postgres.py').existsSync()) return candidate;
    candidate = candidate.parent;
  }
  throw StateError('workspace root not found');
}

Future<ProcessResult> _runMigration(File tool, File snapshot, String namespace, {String? fault}) {
  final dsn = Platform.environment['DARTCLAW_TEST_POSTGRES_URL'];
  if (dsn == null || dsn.isEmpty) throw StateError('DARTCLAW_TEST_POSTGRES_URL is required');
  final uri = Uri.parse(dsn);
  final userInfo = uri.userInfo.split(':');
  final environment = Map<String, String>.of(Platform.environment)
    ..['PGHOST'] = uri.host
    ..['PGPORT'] = '${uri.port}'
    ..['PGDATABASE'] = uri.pathSegments.single
    ..['PGUSER'] = Uri.decodeComponent(userInfo.first)
    ..['PGSSLMODE'] = uri.queryParameters['sslmode'] ?? 'disable'
    ..['PGOPTIONS'] = '-c search_path=$namespace';
  if (userInfo.length > 1) environment['PGPASSWORD'] = Uri.decodeComponent(userInfo.sublist(1).join(':'));
  if (fault == null) {
    environment.remove('DARTCLAW_MIGRATION_FAULT');
  } else {
    environment['DARTCLAW_MIGRATION_FAULT'] = fault;
  }
  return Process.run(
    'python3',
    [tool.path, snapshot.path],
    environment: environment,
    workingDirectory: _workspaceRoot().path,
  );
}

Future<int> _allAuthoritativeRows(PostgresBackend backend) async {
  const tables = [
    'agent_executions',
    'workflow_step_executions',
    'tasks',
    'task_artifacts',
    'goals',
    'task_events',
    'turns',
    'workflow_runs',
    'workflow_run_migrations',
    'kg_facts',
  ];
  var total = 0;
  for (final table in tables) {
    total += (await backend.query('SELECT count(*) AS count FROM "$table"')).single['count']! as int;
  }
  return total;
}

Future<String> _sha256(File file) async => sha256.convert(await file.readAsBytes()).toString();

String _safeResult(ProcessResult result) => 'exit ${result.exitCode}; output intentionally redacted';

void _expectRedacted(ProcessResult result) {
  final output = '${result.stdout}\n${result.stderr}';
  expect(output, isNot(contains('PostgresFixturePasswordX9')));
  expect(output, isNot(contains('DROP TABLE')));
  expect(output, isNot(contains('Göteborg')));
  expect(output, isNot(contains("O'Brien")));
}
