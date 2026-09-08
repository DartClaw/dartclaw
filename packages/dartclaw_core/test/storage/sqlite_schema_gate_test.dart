import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'schema_fixtures.dart';

void main() {
  group('classification', () {
    test('recognizes empty, released, current, and incompatible stores without writes', () async {
      final empty = await _store();
      expect((await _inspect(empty.backend)).state, SqliteSchemaState.empty);
      await empty.close();

      final released = await _store(TasksSchemaFixture.released025);
      expect((await _inspect(released.backend)).state, SqliteSchemaState.releasedUnmarked);
      await released.close();

      final current = await _store(TasksSchemaFixture.upgraded024, 1);
      current.database.execute('CREATE TABLE operator_notes (note TEXT)');
      current.database.execute("INSERT INTO operator_notes VALUES ('keep')");
      final before = _snapshot(current.database);
      final schemaVersion = current.database.select('PRAGMA schema_version').single.values.single;
      expect((await _inspect(current.backend)).state, SqliteSchemaState.current);
      expect(_snapshot(current.database), before);
      expect(current.database.select('PRAGMA schema_version').single.values.single, schemaVersion);
      await current.close();

      final incompatible = await _store(TasksSchemaFixture.ownerlessKg);
      final incompatibleBefore = _snapshot(incompatible.database);
      final inspection = await _inspect(incompatible.backend);
      expect(inspection.state, SqliteSchemaState.incompatible);
      expect(inspection.differences, contains('missing column kg_facts.owner'));
      expect(_snapshot(incompatible.database), incompatibleBefore);
      await incompatible.close();
    });

    test('refuses every malformed marker form', () async {
      for (final marker in <String, List<String>>{
        'empty': [_markerTable],
        'duplicated': [
          'CREATE TABLE dartclaw_schema (id INTEGER, epoch INTEGER)',
          'INSERT INTO dartclaw_schema VALUES (1, 1)',
          'INSERT INTO dartclaw_schema VALUES (2, 1)',
        ],
        'non-integer': [
          'CREATE TABLE dartclaw_schema (id INTEGER, epoch TEXT)',
          "INSERT INTO dartclaw_schema VALUES (1, '1')",
        ],
        '0': [_markerTable, 'INSERT INTO dartclaw_schema VALUES (1, 0)'],
        '2': [_markerTable, 'INSERT INTO dartclaw_schema VALUES (1, 2)'],
      }.entries) {
        final store = await _store(TasksSchemaFixture.released025);
        for (final sql in marker.value) {
          store.database.execute(sql);
        }
        final before = _snapshot(store.database);

        final inspection = await _inspect(store.backend);

        expect(inspection.state, SqliteSchemaState.incompatible, reason: marker.key);
        expect(inspection.foundEpoch, marker.key, reason: marker.key);
        expect(_snapshot(store.database), before, reason: marker.key);
        await store.close();
      }
    });

    test('reserved marker namespace collisions and expression indexes refuse unchanged', () async {
      for (final statements in [
        ['CREATE VIEW dartclaw_schema AS SELECT 1 AS id, 1 AS epoch'],
        ['CREATE INDEX dartclaw_schema ON tasks(status)'],
        ['CREATE TABLE DARTCLAW_SCHEMA(id INTEGER, epoch INTEGER)', 'INSERT INTO DARTCLAW_SCHEMA VALUES(1, 1)'],
        ['DROP INDEX idx_tasks_status', 'CREATE INDEX idx_tasks_status ON tasks(lower(status))'],
      ]) {
        final store = await _store(TasksSchemaFixture.released025);
        for (final sql in statements) {
          store.database.execute(sql);
        }
        final before = _snapshot(store.database);
        final version = store.database.select('PRAGMA schema_version').single.values.single;
        expect((await _inspect(store.backend)).state, SqliteSchemaState.incompatible, reason: '$statements');
        await expectLater(
          SqliteSchemaGate.prepareTasks(store.backend, storeName: 'renamed.db'),
          throwsA(
            isA<SchemaIncompatibleException>()
                .having((error) => error.toString(), 'store', contains('renamed.db'))
                .having((error) => error.toString(), 'guidance', contains('Back up renamed.db'))
                .having((error) => error.toString(), 'reset', contains('reset/recreate')),
          ),
        );
        expect(_snapshot(store.database), before);
        expect(store.database.select('PRAGMA schema_version').single.values.single, version);
        await store.close();
      }
      final store = await _store(TasksSchemaFixture.released025);
      store.database.execute('CREATE TRIGGER dartclaw_schema AFTER INSERT ON goals BEGIN SELECT 1; END');
      final before = _domainSnapshot(store.database);
      expect((await _inspect(store.backend)).state, SqliteSchemaState.releasedUnmarked);
      await SqliteSchemaGate.prepareTasks(store.backend, storeName: 'tasks.db');
      expect((await _inspect(store.backend)).state, SqliteSchemaState.current);
      expect(_domainSnapshot(store.database), before);
      expect(
        store.database.select("SELECT name FROM sqlite_master WHERE type='trigger' AND name='dartclaw_schema'"),
        hasLength(1),
      );
      await store.close();
    });

    test('each column and index compatibility property is required', () async {
      final store = await _store(TasksSchemaFixture.released025);
      final before = _snapshot(store.database);
      final table = SchemaIdentity.tasks.tables.singleWhere((table) => table.name == 'tasks');
      for (final changed in const [
        SchemaColumn('description', 'BLOB', notNull: true),
        SchemaColumn('description', 'TEXT'),
        SchemaColumn('description', 'TEXT', notNull: true, defaultValue: "'changed'"),
        SchemaColumn('description', 'TEXT', notNull: true, primaryKey: true),
      ]) {
        final tables = SchemaIdentity.tasks.tables
            .map(
              (candidate) => candidate == table
                  ? SchemaTable(
                      table.name,
                      table.columns.map((column) => column.name == changed.name ? changed : column).toList(),
                    )
                  : candidate,
            )
            .toList();
        final inspection = await _inspect(store.backend, _identity(tables: tables));
        expect(inspection.state, SqliteSchemaState.incompatible);
        expect(inspection.differences, ['mismatched column tasks.description']);
      }
      for (final changed in const [
        SchemaIndex('idx_tasks_status_type', 'goals', ['status', 'type']),
        SchemaIndex('idx_tasks_status_type', 'tasks', ['status', 'type'], unique: true),
        SchemaIndex('idx_tasks_status_type', 'tasks', ['type', 'status']),
      ]) {
        final indexes = SchemaIdentity.tasks.indexes
            .map((index) => index.name == changed.name ? changed : index)
            .toList();
        final inspection = await _inspect(store.backend, _identity(indexes: indexes));
        expect(inspection.state, SqliteSchemaState.incompatible);
        expect(inspection.differences.single, contains('idx_tasks_status_type'));
      }
      expect(_snapshot(store.database), before);
      await store.close();
    });

    test('checks every required table, column, and index descriptor', () async {
      final store = await _store(TasksSchemaFixture.released025);
      final before = _snapshot(store.database);
      for (final table in SchemaIdentity.tasks.tables) {
        final identity = _identity(tables: [...SchemaIdentity.tasks.tables, SchemaTable('missing_${table.name}', [])]);
        expect((await _inspect(store.backend, identity)).differences, contains('missing table missing_${table.name}'));
        for (final column in table.columns) {
          final changed = SchemaTable(table.name, [
            ...table.columns.where((candidate) => candidate.name != column.name),
            SchemaColumn('missing_${column.name}', column.type),
          ]);
          final tables = SchemaIdentity.tasks.tables
              .map((candidate) => candidate == table ? changed : candidate)
              .toList();
          expect(
            (await _inspect(store.backend, _identity(tables: tables))).differences,
            contains('missing column ${table.name}.missing_${column.name}'),
          );
        }
      }
      for (final index in SchemaIdentity.tasks.indexes) {
        final changed = SchemaIndex(index.name, index.table, [
          ...index.columns,
          'missing_column',
        ], unique: index.unique);
        final indexes = SchemaIdentity.tasks.indexes
            .map((candidate) => candidate == index ? changed : candidate)
            .toList();
        expect(
          (await _inspect(store.backend, _identity(indexes: indexes))).differences,
          contains('mismatched index ${index.name}'),
        );
      }
      expect(_snapshot(store.database), before);
      await store.close();
    });
  });

  group('authoritative tasks store', () {
    test('fresh bootstrap and compatible reopen are complete and idempotent', () async {
      final store = await _store();

      await SqliteSchemaGate.prepareTasks(store.backend, storeName: 'tasks.db');

      expect((await _inspect(store.backend)).state, SqliteSchemaState.current);
      expect(store.database.select('SELECT id, epoch FROM dartclaw_schema'), hasLength(1));
      final before = _snapshot(store.database);
      final schemaVersion = store.database.select('PRAGMA schema_version').single.values.single;

      await SqliteSchemaGate.prepareTasks(store.backend, storeName: 'tasks.db');

      expect(_snapshot(store.database), before);
      expect(store.database.select('PRAGMA schema_version').single.values.single, schemaVersion);
      await store.close();
    });

    test('adopts both released variants without changing domain schema or data', () async {
      for (final fixture in [TasksSchemaFixture.released025, TasksSchemaFixture.upgraded024]) {
        final store = await _store(fixture);
        store.database.execute(
          "INSERT INTO goals (id, title, mission, created_at, max_tokens) VALUES ('g1', 'Goal', 'Mission', 'now', 42)",
        );
        store.database.execute("INSERT INTO workflow_run_migrations VALUES ('m1', 'now')");
        final before = _domainSnapshot(store.database);

        await SqliteSchemaGate.prepareTasks(store.backend, storeName: 'tasks.db');

        expect(_domainSnapshot(store.database), before, reason: '$fixture');
        expect((await _inspect(store.backend)).state, SqliteSchemaState.current);
        await store.close();
      }
    });

    test('refuses unsupported authoritative shapes unchanged with guidance', () async {
      for (final fixture in [
        TasksSchemaFixture.ownerlessKg,
        TasksSchemaFixture.goalsWithoutMaxTokens,
        TasksSchemaFixture.legacyTasks,
      ]) {
        final store = await _store(fixture);
        final before = _snapshot(store.database);
        final schemaVersion = store.database.select('PRAGMA schema_version').single.values.single;

        await expectLater(
          SqliteSchemaGate.prepareTasks(store.backend, storeName: 'renamed.db'),
          throwsA(
            isA<SchemaIncompatibleException>()
                .having((error) => error.toString(), 'message', contains('renamed.db'))
                .having((error) => error.toString(), 'guidance', contains('Back up renamed.db'))
                .having((error) => error.toString(), 'reset', contains('reset/recreate')),
          ),
        );

        expect(_snapshot(store.database), before, reason: '$fixture');
        expect(store.database.select('PRAGMA schema_version').single.values.single, schemaVersion);
        await store.close();
      }

      final foreign = await _store();
      foreign.database.execute('CREATE TABLE operator_notes (note TEXT)');
      final before = _snapshot(foreign.database);
      await expectLater(
        SqliteSchemaGate.prepareTasks(foreign.backend, storeName: 'tasks.db'),
        throwsA(isA<SchemaIncompatibleException>()),
      );
      expect(_snapshot(foreign.database), before);
      await foreign.close();
    });
  });
}

const _markerTable = '''
  CREATE TABLE dartclaw_schema (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    epoch INTEGER NOT NULL CHECK (typeof(epoch) = 'integer')
  )
''';

Future<({Database database, DatabaseBackend backend, Future<void> Function() close})> _store([
  TasksSchemaFixture? fixture,
  int? markedEpoch,
]) async {
  final database = sqlite3.openInMemory();
  if (fixture != null) createTasksSchemaFixture(database, fixture);
  if (markedEpoch != null) {
    database.execute(_markerTable);
    database.execute('INSERT INTO dartclaw_schema VALUES (1, ?)', [markedEpoch]);
  }
  final backend = SqliteBackend(database);
  return (database: database, backend: backend, close: backend.close);
}

Future<SqliteSchemaInspection> _inspect(DatabaseBackend backend, [SchemaIdentity identity = SchemaIdentity.tasks]) =>
    SqliteSchemaGate.inspect(backend, identity, storeName: 'tasks.db');

SchemaIdentity _identity({List<SchemaTable>? tables, List<SchemaIndex>? indexes}) => SchemaIdentity(
  tables: tables ?? SchemaIdentity.tasks.tables,
  indexes: indexes ?? SchemaIdentity.tasks.indexes,
  sqliteObjects: SchemaIdentity.tasks.sqliteObjects,
  bootstrapStatements: SchemaIdentity.tasks.bootstrapStatements,
);

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

String _domainSnapshot(Database database) {
  final snapshot = jsonDecode(_snapshot(database)) as Map<String, dynamic>;
  final objects = (snapshot['objects'] as List).where((row) => (row as List)[1] != 'dartclaw_schema').toList();
  final data = Map<String, dynamic>.from(snapshot['data'] as Map)..remove('dartclaw_schema');
  return jsonEncode({'objects': objects, 'data': data});
}
