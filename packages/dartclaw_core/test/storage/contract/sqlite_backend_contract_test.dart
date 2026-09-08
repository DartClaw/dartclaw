import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';

import '../failing_database_backend.dart';
import '../schema_fixtures.dart';
import 'database_backend_contract.dart';

void main() {
  databaseBackendContractTests(name: 'SQLite', open: _openSqliteContract, kind: ContractBackendKind.sqlite);
}

Future<ContractBackend> _openSqliteContract() async {
  final taskDatabase = sqlite3.openInMemory();
  createTasksSchemaFixture(taskDatabase, TasksSchemaFixture.released025);
  final taskBackend = SqliteBackend(taskDatabase);
  await SqliteSchemaGate.prepareTasks(taskBackend, storeName: 'contract tasks');

  final searchDatabase = sqlite3.openInMemory();
  final searchBackend = SqliteBackend(searchDatabase);
  await SqliteSchemaGate.prepareSearch(searchBackend, storeName: 'contract search');
  final index = SqliteFtsIndex(searchBackend, table: SqliteFtsTable.memoryChunks);

  Future<void> resetTasks() async {
    taskDatabase.execute('PRAGMA foreign_keys=OFF');
    final objects = taskDatabase.select(
      "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'trigger' THEN 0 ELSE 1 END",
    );
    for (final row in objects) {
      final type = row['type'] as String;
      final name = row['name'] as String;
      if (type == 'table' || type == 'view' || type == 'trigger') {
        taskDatabase.execute('DROP ${type.toUpperCase()} IF EXISTS "$name"');
      }
    }
    taskDatabase.execute('PRAGMA foreign_keys=ON');
  }

  final schema = ContractSchemaAdapter(
    prepare: () => SqliteSchemaGate.prepareTasks(taskBackend, storeName: 'contract tasks'),
    snapshot: () async => _snapshot(taskDatabase),
    verifyRequiredSchema: () => _verifySqliteRequiredSchema(taskDatabase),
    seedAuthoritativeData: () => taskBackend
        .execute('INSERT INTO goals (id, title, mission, created_at, max_tokens) VALUES (?, ?, ?, ?, ?)', [
          'schema-sentinel',
          'Schema sentinel',
          'Preserve authoritative data',
          '2026-09-09T10:11:12.000Z',
          73,
        ])
        .then((_) {}),
    readAuthoritativeData: () => taskBackend.query(
      'SELECT id, title, mission, created_at, max_tokens FROM goals WHERE id = ?',
      ['schema-sentinel'],
    ),
    prepareAndCountWrites: () async {
      final recording = FailingDatabaseBackend(taskBackend, failAt: 1 << 30);
      await SqliteSchemaGate.prepareTasks(recording, storeName: 'contract tasks');
      return recording.executeCount;
    },
    reset: resetTasks,
    setEpoch: (epoch) => taskBackend.execute('UPDATE dartclaw_schema SET epoch = ?', [epoch]).then((_) {}),
    removeMarker: () => taskBackend.execute('DELETE FROM dartclaw_schema').then((_) {}),
    duplicateMarker: () async {
      await taskBackend.execute('DROP TABLE dartclaw_schema');
      await taskBackend.execute('CREATE TABLE dartclaw_schema (id INTEGER, epoch INTEGER)');
      await taskBackend.execute('INSERT INTO dartclaw_schema VALUES (1, 1)');
      await taskBackend.execute('INSERT INTO dartclaw_schema VALUES (2, 1)');
    },
    setTextEpoch: () async {
      await taskBackend.execute('DROP TABLE dartclaw_schema');
      await taskBackend.execute('CREATE TABLE dartclaw_schema (id INTEGER, epoch TEXT)');
      await taskBackend.execute("INSERT INTO dartclaw_schema VALUES (1, '1')");
    },
    dropRequiredTable: () => taskBackend.execute('DROP TABLE goals').then((_) {}),
    dropRequiredColumn: () => taskBackend.execute('ALTER TABLE goals DROP COLUMN max_tokens').then((_) {}),
    dropRequiredIndex: () => taskBackend.execute('DROP INDEX idx_tasks_status').then((_) {}),
    addOrphans: () async {
      await taskBackend.execute('ALTER TABLE workflow_step_executions ADD COLUMN external_artifact_mount TEXT');
      await taskBackend.execute('CREATE TABLE operator_notes (note TEXT)');
      await taskBackend.execute("INSERT INTO operator_notes VALUES ('keep')");
    },
    bootstrapStatementCount: SchemaIdentity.tasks.bootstrapStatements.length + 2,
    prepareWithFailure: (statementNumber) async {
      final failing = FailingDatabaseBackend(taskBackend, failAt: statementNumber);
      await SqliteSchemaGate.prepareTasks(failing, storeName: 'contract tasks');
    },
    proveDerivedRebuild: () async {
      final root = Directory.systemTemp.createTempSync('dartclaw_contract_search_');
      try {
        await searchBackend.execute('DROP TABLE memory_chunks_fts');
        final health = IndexHealthStore(workspaceDir: root.path);
        await SqliteSchemaGate.prepareSearch(
          searchBackend,
          storeName: 'contract search',
          rebuild: SqliteSearchRebuild(
            manifestRevision: 1,
            manifestFingerprint: 'contract',
            healthStore: health,
            populate: (tx) => tx
                .execute('INSERT INTO memory_chunks (text, source, user_id) VALUES (?, ?, ?)', [
                  'reconstructed orchid',
                  'contract',
                  'u-alpha',
                ])
                .then((_) {}),
            authenticateComplete: () async => true,
          ),
        );
        final inspection = await SqliteSchemaGate.inspect(
          searchBackend,
          SchemaIdentity.search,
          storeName: 'contract search',
        );
        if (inspection.state != SqliteSchemaState.current) {
          throw StateError('Derived schema did not converge');
        }
        final refusedDatabase = sqlite3.openInMemory();
        final refused = SqliteBackend(refusedDatabase);
        try {
          await SqliteSchemaGate.prepareSearch(refused, storeName: 'contract refused search');
          await refused.execute('DROP TABLE memory_chunks_fts');
          final before = _snapshot(refusedDatabase);
          try {
            await SqliteSchemaGate.prepareSearch(refused, storeName: 'contract refused search');
            throw StateError('Expected incomplete rebuild refusal');
          } on SchemaIncompatibleException {
            if (_snapshot(refusedDatabase) != before) {
              throw StateError('Refused derived store changed');
            }
          }
        } finally {
          await refused.close();
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );

  return ContractBackend(
    backend: taskBackend,
    searchBackend: searchBackend,
    index: index,
    schema: schema,
    engine: 'sqlite',
    blobType: 'BLOB',
    close: () async {
      await searchBackend.close();
      await taskBackend.close();
    },
  );
}

Future<void> _verifySqliteRequiredSchema(Database database) {
  final objects = database.select(
    "SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND type IN ('table', 'index')",
  );
  final tables = objects.where((row) => row['type'] == 'table').map((row) => row['name'] as String).toSet();
  final indexes = objects.where((row) => row['type'] == 'index').map((row) => row['name'] as String).toSet();
  final marker = database.select('SELECT id, epoch FROM dartclaw_schema');
  if (!_sameSet(tables, requiredTaskTables) ||
      !_sameSet(indexes, requiredTaskIndexes) ||
      marker.length != 1 ||
      marker.single['id'] != 1 ||
      marker.single['epoch'] != SchemaIdentity.currentEpoch) {
    throw StateError('Fresh SQLite schema does not match the required object and marker manifest');
  }
  return Future.value();
}

bool _sameSet(Set<String> left, Set<String> right) => left.length == right.length && left.containsAll(right);

String _snapshot(Database database) {
  final objects = database.select(
    "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
  );
  final data = <String, Object?>{};
  for (final row in objects.where((row) => row['type'] == 'table')) {
    final name = row['name'] as String;
    if (name.startsWith('memory_chunks_fts')) continue;
    data[name] = database.select('SELECT * FROM "$name"').map((item) => item.values.toList()).toList();
  }
  return jsonEncode({'objects': objects.map((row) => row.values.toList()).toList(), 'data': data});
}
