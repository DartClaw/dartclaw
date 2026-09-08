import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('storage-wiring-task-gate-');
    eventBus = EventBus();
  });

  tearDown(() async {
    if (!eventBus.isDisposed) await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('tasks store is prepared before any repository is constructed', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final wiring = _wiring(config, eventBus);

    await wiring.wire();

    final database = sqlite3.open(config.dartclawDbPath);
    try {
      final marker = database.select('SELECT id, epoch FROM dartclaw_schema').single;
      expect([marker['id'], marker['epoch']], [1, 1]);
      final tables = database
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'])
          .toSet();
      expect(
        tables,
        containsAll([
          'agent_executions',
          'workflow_step_executions',
          'tasks',
          'task_artifacts',
          'goals',
          'task_events',
          'turns',
          'kg_facts',
          'workflow_runs',
        ]),
      );
    } finally {
      database.close();
    }

    await wiring.dispose();
  });

  for (final variant in const {
    'released unmarked store opens unchanged': false,
    'released unmarked 0.24-upgraded store opens unchanged': true,
  }.entries) {
    test(variant.key, () async {
      final variantDir = Directory(p.join(tempDir.path, variant.value ? 'upgraded' : 'fresh'))..createSync();
      final config = DartclawConfig(server: ServerConfig(dataDir: variantDir.path));
      await _prepareReleasedStore(config.dartclawDbPath, withOrphanColumn: variant.value);
      final before = _storeSnapshot(config.dartclawDbPath);
      final wiring = _wiring(config, eventBus);

      await wiring.wire();

      final after = _storeSnapshot(config.dartclawDbPath);
      expect(after.schema, before.schema);
      expect(after.tasks, before.tasks);
      final database = sqlite3.open(config.dartclawDbPath);
      try {
        expect(database.select('SELECT id, epoch FROM dartclaw_schema').single['epoch'], 1);
      } finally {
        database.close();
      }
      await wiring.dispose();
    });
  }

  test('legacy store is adopted before schema preparation', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final legacyPath = p.join(tempDir.path, 'tasks.db');
    await _prepareReleasedStore(legacyPath, withOrphanColumn: false);
    final before = _storeSnapshot(legacyPath);
    final wiring = _wiring(config, eventBus);

    await wiring.wire();

    expect(File(legacyPath).existsSync(), isFalse);
    expect(File(config.dartclawDbPath).existsSync(), isTrue);
    final after = _storeSnapshot(config.dartclawDbPath);
    expect(after.schema, before.schema);
    expect(after.tasks, before.tasks);
    await wiring.dispose();
  });

  test('both store filenames refuse before the task backend opens', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final legacyPath = p.join(tempDir.path, 'tasks.db');
    File(config.dartclawDbPath).writeAsBytesSync([1, 2, 3]);
    File(legacyPath).writeAsBytesSync([4, 5]);
    var taskBackendOpens = 0;
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchBackendFactory: (_) async => SqliteBackend.openInMemory(),
      taskBackendFactory: (_) async {
        taskBackendOpens++;
        return SqliteBackend.openInMemory();
      },
      exitFn: (code) => throw _Exit(code),
      personalMemoryEnabled: false,
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));

    expect(taskBackendOpens, 0);
    final diagnostic = records
        .where((record) => record.level == Level.SEVERE)
        .map((record) => '${record.message} ${record.error}')
        .join('\n');
    expect(diagnostic, contains('dartclaw.db'));
    expect(diagnostic, contains('tasks.db'));
    expect(diagnostic.toLowerCase(), contains('ambiguous'));
    expect(File(config.dartclawDbPath).readAsBytesSync(), [1, 2, 3]);
    expect(File(legacyPath).readAsBytesSync(), [4, 5]);
  });

  test('current store opens without changing domain data', () async {
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    await _prepareCurrentStore(config.dartclawDbPath);
    final before = _storeSnapshot(config.dartclawDbPath);
    final wiring = _wiring(config, eventBus);

    await wiring.wire();

    final after = _storeSnapshot(config.dartclawDbPath);
    expect(after.schema, before.schema);
    expect(after.tasks, before.tasks);
    await wiring.dispose();
  });

  test('incompatible store exits before repository use and remains unchanged', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    final database = sqlite3.open(config.dartclawDbPath);
    database
      ..execute('CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL)')
      ..execute("INSERT INTO tasks (id, title) VALUES ('legacy-1', 'Legacy')");
    database.close();
    final before = _storeSnapshot(config.dartclawDbPath);
    final wiring = _wiring(config, eventBus);

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));

    expect(
      records,
      contains(
        isA<LogRecord>()
            .having((record) => record.level, 'level', Level.SEVERE)
            .having((record) => record.message, 'message', contains('Cannot open task database')),
      ),
    );
    final after = _storeSnapshot(config.dartclawDbPath);
    expect(after.schema, before.schema);
    expect(after.tasks, before.tasks);
  });
}

StorageWiring _wiring(DartclawConfig config, EventBus eventBus) {
  return StorageWiring(
    config: config,
    eventBus: eventBus,
    searchBackendFactory: (_) async => SqliteBackend.openInMemory(),
    taskBackendFactory: SqliteBackend.open,
    exitFn: (code) => throw _Exit(code),
    personalMemoryEnabled: false,
  );
}

Future<void> _prepareCurrentStore(String path) async {
  final backend = await SqliteBackend.open(path);
  await SqliteSchemaGate.prepareTasks(backend, storeName: 'tasks.db');
  await backend.execute(
    '''
    INSERT INTO tasks (id, title, description, type, status, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ''',
    ['task-1', 'Existing', 'Preserve me', taskTypeStoragePlaceholder, 'draft', '2026-09-08T00:00:00.000Z'],
  );
  await backend.close();
}

Future<void> _prepareReleasedStore(String path, {required bool withOrphanColumn}) async {
  await _prepareCurrentStore(path);
  final database = sqlite3.open(path);
  database.execute('DROP TABLE dartclaw_schema');
  if (withOrphanColumn) {
    database.execute('ALTER TABLE workflow_step_executions ADD COLUMN external_artifact_mount TEXT');
  }
  database.close();
}

({List<Map<String, Object?>> schema, List<Map<String, Object?>> tasks}) _storeSnapshot(String path) {
  final database = sqlite3.open(path);
  try {
    final schema = database
        .select('''
          SELECT type, name, tbl_name, sql
          FROM sqlite_master
          WHERE name NOT LIKE 'sqlite_%'
            AND name <> 'dartclaw_schema'
          ORDER BY type, name
          ''')
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    final tasks = database
        .select('SELECT * FROM tasks ORDER BY id')
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    return (schema: schema, tasks: tasks);
  } finally {
    database.close();
  }
}

final class _Exit implements Exception {
  const new(this.code);

  final int code;
}
