import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show SchemaIncompatibleException;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'failing_database_backend.dart';
import 'schema_fixtures.dart';

void main() {
  test('every DDL prefix rolls back and a clean retry converges', () async {
    final taskBootstrapCount = SchemaIdentity.tasks.bootstrapStatements.length + 2;
    for (var failAt = 1; failAt <= taskBootstrapCount; failAt++) {
      final database = sqlite3.openInMemory();
      final failing = FailingDatabaseBackend(SqliteBackend(database), failAt: failAt);
      final before = _snapshot(database);

      await expectLater(SqliteSchemaGate.prepareTasks(failing, storeName: 'tasks.db'), throwsStateError);

      expect(_snapshot(database), before, reason: 'fresh tasks statement $failAt');
      expect(_hasMarker(database), isFalse, reason: 'fresh tasks statement $failAt');
      failing.disableFailure();
      await SqliteSchemaGate.prepareTasks(failing, storeName: 'tasks.db');
      expect(await _state(failing, SchemaIdentity.tasks, 'tasks.db'), SqliteSchemaState.current);
      await failing.close();
    }

    final searchBootstrapCount = SchemaIdentity.search.bootstrapStatements.length + 2;
    for (var failAt = 1; failAt <= searchBootstrapCount; failAt++) {
      final database = sqlite3.openInMemory();
      final failing = FailingDatabaseBackend(SqliteBackend(database), failAt: failAt);
      final before = _snapshot(database);

      await expectLater(SqliteSchemaGate.prepareSearch(failing, storeName: 'search.db'), throwsStateError);

      expect(_snapshot(database), before, reason: 'fresh search statement $failAt');
      expect(_hasMarker(database), isFalse, reason: 'fresh search statement $failAt');
      failing.disableFailure();
      await SqliteSchemaGate.prepareSearch(failing, storeName: 'search.db');
      expect(await _state(failing, SchemaIdentity.search, 'search.db'), SqliteSchemaState.current);
      await failing.close();
    }

    for (var failAt = 1; failAt <= 2; failAt++) {
      final database = sqlite3.openInMemory();
      createTasksSchemaFixture(database, TasksSchemaFixture.upgraded024);
      database.execute("INSERT INTO goals (id, title, mission, created_at) VALUES ('g1', 'Goal', 'Mission', 'now')");
      final failing = FailingDatabaseBackend(SqliteBackend(database), failAt: failAt);
      final before = _snapshot(database);

      await expectLater(SqliteSchemaGate.prepareTasks(failing, storeName: 'tasks.db'), throwsStateError);

      expect(_snapshot(database), before, reason: 'adoption statement $failAt');
      expect(_hasMarker(database), isFalse, reason: 'adoption statement $failAt');
      failing.disableFailure();
      await SqliteSchemaGate.prepareTasks(failing, storeName: 'tasks.db');
      expect(await _state(failing, SchemaIdentity.tasks, 'tasks.db'), SqliteSchemaState.current);
      await failing.close();
    }

    final rebuildStatementCount =
        SchemaIdentity.search.dropStatements.length + SchemaIdentity.search.bootstrapStatements.length + 2;
    for (var failAt = 1; failAt <= rebuildStatementCount; failAt++) {
      final root = Directory.systemTemp.createTempSync('schema_gate_rollback_');
      final health = IndexHealthStore(workspaceDir: root.path);
      final database = sqlite3.openInMemory();
      create023SearchSchema(database);
      database.execute("INSERT INTO memory_chunks (text, source) VALUES ('prior', 'legacy')");
      final failing = FailingDatabaseBackend(SqliteBackend(database), failAt: failAt);
      final before = _snapshot(database);
      final rebuild = SqliteSearchRebuild(
        manifestRevision: 11,
        manifestFingerprint: 'fingerprint-11',
        healthStore: health,
        populate: (tx) async {
          await tx.execute("INSERT INTO memory_chunks (text, source) VALUES ('rebuilt', 'canonical')");
        },
        authenticateComplete: () async => true,
      );

      await expectLater(
        SqliteSchemaGate.prepareSearch(failing, storeName: 'search.db', rebuild: rebuild),
        throwsA(isA<SchemaIncompatibleException>()),
      );

      expect(_snapshot(database), before, reason: 'search rebuild statement $failAt');
      expect(_hasMarker(database), isFalse, reason: 'search rebuild statement $failAt');
      final evidence = await health.read(canonicalRevision: 11, canonicalFingerprint: 'fingerprint-11');
      expect(evidence.state, IndexHealthState.degraded, reason: 'search rebuild statement $failAt');
      expect(evidence.failureStage, 'schema-rebuild', reason: 'search rebuild statement $failAt');

      failing.disableFailure();
      await SqliteSchemaGate.prepareSearch(failing, storeName: 'search.db', rebuild: rebuild);
      expect(await _state(failing, SchemaIdentity.search, 'search.db'), SqliteSchemaState.current);
      await failing.close();
      root.deleteSync(recursive: true);
    }
  });
}

Future<SqliteSchemaState> _state(FailingDatabaseBackend backend, SchemaIdentity identity, String storeName) async =>
    (await SqliteSchemaGate.inspect(backend, identity, storeName: storeName)).state;

bool _hasMarker(Database database) =>
    database.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'dartclaw_schema'").isNotEmpty;

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
  return jsonEncode({
    'schemaVersion': database.select('PRAGMA schema_version').single.values.single,
    'objects': objects.map((row) => row.values.toList()).toList(),
    'data': data,
  });
}
