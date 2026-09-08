import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'schema_fixtures.dart';

void main() {
  test('manifests describe the released 0.25 fixtures exactly', () async {
    expect(SchemaIdentity.tasks.tables, hasLength(10));
    expect(SchemaIdentity.tasks.indexes, hasLength(21));
    expect(SchemaIdentity.search.sqliteObjects, hasLength(4));

    for (final fixture in [TasksSchemaFixture.released025, TasksSchemaFixture.upgraded024]) {
      final database = sqlite3.openInMemory();
      final backend = SqliteBackend(database);
      createTasksSchemaFixture(database, fixture);
      _expectExactManifest(database, SchemaIdentity.tasks, orphan: fixture == TasksSchemaFixture.upgraded024);

      final inspection = await SqliteSchemaGate.inspect(backend, SchemaIdentity.tasks, storeName: 'tasks.db');

      expect(inspection.state, SqliteSchemaState.releasedUnmarked, reason: '$fixture: ${inspection.differences}');
      expect(inspection.differences, isEmpty);
      await backend.close();
    }

    final database = sqlite3.openInMemory();
    final backend = SqliteBackend(database);
    createReleased025SearchSchema(database);
    _expectExactManifest(database, SchemaIdentity.search);

    final inspection = await SqliteSchemaGate.inspect(backend, SchemaIdentity.search, storeName: 'search.db');

    expect(inspection.state, SqliteSchemaState.releasedUnmarked, reason: '${inspection.differences}');
    expect(inspection.differences, isEmpty);
    await backend.close();
  });
}

void _expectExactManifest(Database database, SchemaIdentity identity, {bool orphan = false}) {
  final objects = database.select("SELECT type, name, tbl_name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
  expect(
    objects
        .where((row) => row['type'] == 'table' && !(row['name'] as String).startsWith('memory_chunks_fts'))
        .map((row) => row['name']),
    unorderedEquals(identity.tables.map((table) => table.name)),
  );
  for (final table in identity.tables) {
    final columns = database
        .select('PRAGMA table_info("${table.name}")')
        .where(
          (row) => !(orphan && table.name == 'workflow_step_executions' && row['name'] == 'external_artifact_mount'),
        );
    expect(
      columns.map((row) => (row['name'], row['type'], row['notnull'] == 1, row['dflt_value'], row['pk'] != 0)),
      unorderedEquals(
        table.columns.map(
          (column) => (column.name, column.type, column.notNull, column.defaultValue, column.primaryKey),
        ),
      ),
      reason: table.name,
    );
  }
  expect(
    objects.where((row) => row['type'] == 'index').map((row) => (row['name'], row['tbl_name'])),
    unorderedEquals(identity.indexes.map((index) => (index.name, index.table))),
  );
  for (final index in identity.indexes) {
    final live = database.select('PRAGMA index_list("${index.table}")').singleWhere((row) => row['name'] == index.name);
    expect(live['unique'] == 1, index.unique, reason: index.name);
    expect(
      database.select('PRAGMA index_info("${index.name}")').map((row) => row['name']),
      index.columns,
      reason: index.name,
    );
  }
  expect(
    objects
        .where((row) => row['type'] == 'trigger' || row['name'] == 'memory_chunks_fts')
        .map((row) => (row['type'], row['name'], row['tbl_name'])),
    unorderedEquals(identity.sqliteObjects.map((object) => (object.type, object.name, object.table))),
  );
}
