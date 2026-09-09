@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../failing_database_backend.dart';
import '../postgres_live_support.dart';
import 'database_backend_contract.dart';

void main() {
  databaseBackendContractTests(name: 'PostgreSQL', open: _openPostgresContract, kind: ContractBackendKind.postgres);
}

Future<ContractBackend> _openPostgresContract() async {
  final ready = Completer<({PostgresBackend backend, String namespace})>();
  final release = Completer<void>();
  final lifetime = withPostgresBackend((backend, namespace) async {
    await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
    ready.complete((backend: backend, namespace: namespace));
    await release.future;
  });
  unawaited(
    lifetime.catchError((Object error, StackTrace stackTrace) {
      if (!ready.isCompleted) ready.completeError(error, stackTrace);
    }),
  );
  final opened = await ready.future;
  final backend = opened.backend;
  final namespace = opened.namespace;

  Future<void> reset() async {
    await backend.execute('DROP SCHEMA "$namespace" CASCADE');
    await backend.execute('CREATE SCHEMA "$namespace"');
  }

  final schema = ContractSchemaAdapter(
    prepare: () => PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity),
    snapshot: () => _postgresSnapshot(backend),
    verifyRequiredSchema: () => _verifyPostgresRequiredSchema(backend),
    seedAuthoritativeData: () => backend
        .execute('INSERT INTO goals (id, title, mission, created_at, max_tokens) VALUES (?, ?, ?, ?, ?)', [
          'schema-sentinel',
          'Schema sentinel',
          'Preserve authoritative data',
          '2026-09-09T10:11:12.000Z',
          73,
        ])
        .then((_) {}),
    readAuthoritativeData: () =>
        backend.query('SELECT id, title, mission, created_at, max_tokens FROM goals WHERE id = ?', ['schema-sentinel']),
    prepareAndCountWrites: () async {
      final recording = FailingDatabaseBackend(backend, failAt: 1 << 30);
      await PostgresSchemaGate.prepare(recording, databaseIdentity: backend.databaseIdentity);
      return recording.executeCount;
    },
    reset: reset,
    setEpoch: (epoch) => backend.execute('UPDATE dartclaw_schema SET epoch = ?', [epoch]).then((_) {}),
    removeMarker: () => backend.execute('DELETE FROM dartclaw_schema').then((_) {}),
    duplicateMarker: () async {
      await backend.execute('DROP TABLE dartclaw_schema');
      await backend.execute('CREATE TABLE dartclaw_schema (id bigint, epoch bigint)');
      await backend.execute('INSERT INTO dartclaw_schema VALUES (1, 1), (2, 1)');
    },
    setTextEpoch: () async {
      await backend.execute('DROP TABLE dartclaw_schema');
      await backend.execute('CREATE TABLE dartclaw_schema (id bigint, epoch text)');
      await backend.execute("INSERT INTO dartclaw_schema VALUES (1, '1')");
    },
    dropRequiredTable: () => backend.execute('DROP TABLE goals').then((_) {}),
    dropRequiredColumn: () => backend.execute('ALTER TABLE goals DROP COLUMN max_tokens').then((_) {}),
    dropRequiredIndex: () => backend.execute('DROP INDEX idx_tasks_status').then((_) {}),
    addOrphans: () async {
      await backend.execute('ALTER TABLE workflow_step_executions ADD COLUMN external_artifact_mount text');
      await backend.execute('CREATE TABLE operator_notes (note text)');
      await backend.execute("INSERT INTO operator_notes VALUES ('keep')");
    },
    bootstrapStatementCount: SchemaIdentity.tasks.bootstrapStatements.length + 8,
    prepareWithFailure: (statementNumber) async {
      final failing = FailingDatabaseBackend(backend, failAt: statementNumber);
      await PostgresSchemaGate.prepare(failing, databaseIdentity: backend.databaseIdentity);
    },
  );

  final index = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'english');
  return ContractBackend(
    backend: backend,
    searchBackend: backend,
    index: index,
    schema: schema,
    engine: 'postgres',
    blobType: 'BYTEA',
    lexemeOf: (term) async {
      final rows = await backend.query("SELECT unnest(tsvector_to_array(to_tsvector('english', ?))) AS lexeme", [term]);
      return rows.length == 1 ? rows.single['lexeme'] as String? : null;
    },
    close: () async {
      if (!release.isCompleted) release.complete();
      await lifetime;
    },
  );
}

Future<void> _verifyPostgresRequiredSchema(DatabaseBackend backend) async {
  final tableRows = await backend.query('''
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = current_schema()
  ''');
  final indexRows = await backend.query('''
    SELECT indexname
    FROM pg_indexes
    WHERE schemaname = current_schema() AND indexname NOT LIKE '%_pkey'
  ''');
  final tables = tableRows.map((row) => row['table_name']).whereType<String>().toSet();
  final indexes = indexRows.map((row) => row['indexname']).whereType<String>().toSet();
  final marker = await backend.query('SELECT id, epoch FROM dartclaw_schema');
  if (!_sameSet(tables, {...requiredTaskTables, 'memory_chunks', 'conversation_chunks'}) ||
      !_sameSet(indexes, {
        ...requiredTaskIndexes,
        'memory_chunks_content_tsv_idx',
        'conversation_chunks_content_tsv_idx',
      }) ||
      marker.length != 1 ||
      marker.single['id'] != 1 ||
      marker.single['epoch'] != SchemaIdentity.currentEpoch) {
    throw StateError('Fresh PostgreSQL schema does not match the required object and marker manifest');
  }
}

bool _sameSet(Set<String> left, Set<String> right) => left.length == right.length && left.containsAll(right);

Future<String> _postgresSnapshot(DatabaseBackend backend) async {
  final catalog = await backend.query('''
    SELECT 'column' AS kind, table_name AS parent, column_name AS name,
           data_type || ':' || is_nullable || ':' || coalesce(column_default, '') AS definition
    FROM information_schema.columns
    WHERE table_schema = current_schema()
    UNION ALL
    SELECT 'index', tablename, indexname, indexdef
    FROM pg_indexes
    WHERE schemaname = current_schema()
    ORDER BY kind, parent, name
  ''');
  List<Map<String, Object?>> marker;
  try {
    marker = await backend.query('SELECT id::text AS id, epoch::text AS epoch FROM dartclaw_schema ORDER BY id');
  } catch (_) {
    marker = const [];
  }
  return jsonEncode({'catalog': catalog, 'marker': marker});
}
