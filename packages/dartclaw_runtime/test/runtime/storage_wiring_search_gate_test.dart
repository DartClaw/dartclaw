import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/storage/index_reconciler.dart' show IndexReconcileTransition;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show seedCanonicalMemory;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('storage-wiring-search-gate-');
    eventBus = EventBus();
  });

  tearDown(() async {
    if (!eventBus.isDisposed) await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('an incompatible search store is rebuilt by the gate before the reconciler fast path', () async {
    final config = await _seedConfig(tempDir);
    _createLegacySearchStore(config.searchDbPath);
    final healthStore = IndexHealthStore(workspaceDir: config.workspaceDir);
    final corpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
    final expectedManifest = await corpus.manifest();
    await corpus.close();
    final transitions = <IndexReconcileTransition>[];
    var healthWasCurrentWhenGateClosed = false;
    var searchOpenCount = 0;
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchBackendFactory: (path) async {
        searchOpenCount++;
        final backend = await SqliteBackend.open(path);
        if (searchOpenCount != 1) return backend;
        return _CloseObserverBackend(backend, () async {
          final health = await healthStore.read(
            canonicalRevision: expectedManifest.collectionRevision,
            canonicalFingerprint: expectedManifest.fingerprint,
          );
          healthWasCurrentWhenGateClosed = health.isCurrent(
            expectedManifest.collectionRevision,
            expectedManifest.fingerprint,
          );
        });
      },
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      indexReconciler: CanonicalIndexReconciler(
        targetPath: config.searchDbPath,
        healthStore: healthStore,
        transitionHook: (transition) async => transitions.add(transition),
      ),
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();

    final manifest = await wiring.memoryCorpus.manifest();
    final currentCorpus = await wiring.memoryCorpus.readCorpus();
    final expectedRows = MemoryIndexProjection.chunkCount(MemoryIndexProjection.documents(currentCorpus));
    final database = sqlite3.open(config.searchDbPath);
    try {
      final marker = database.select('SELECT id, epoch FROM dartclaw_schema').single;
      expect([marker['id'], marker['epoch']], [1, 1]);
      expect(database.select('SELECT COUNT(*) AS count FROM memory_chunks').single['count'], expectedRows);
    } finally {
      database.close();
    }
    final health = await wiring.indexHealth.read(
      canonicalRevision: manifest.collectionRevision,
      canonicalFingerprint: manifest.fingerprint,
    );
    expect(healthWasCurrentWhenGateClosed, isTrue);
    expect(health.isCurrent(manifest.collectionRevision, manifest.fingerprint), isTrue);
    expect(transitions, isNot(contains(IndexReconcileTransition.siblingCreated)));
    expect((await wiring.memoryIndex.search('Gate rebuild fact', userId: 'owner')).single.chunk, contains('fact'));
    await wiring.dispose();
  });

  test('a search gate refusal preserves the store and evidence and skips reconciliation', () async {
    final config = await _seedConfig(tempDir);
    _createLegacySearchStore(config.searchDbPath);
    final beforeStore = _storeSnapshot(config.searchDbPath);
    final evidence = File(p.join(config.workspaceDir, '.dartclaw-memory-index.json'))..writeAsStringSync('{not-json');
    final beforeEvidence = evidence.readAsBytesSync();
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final transitions = <IndexReconcileTransition>[];
    var exitCalled = false;
    final healthStore = IndexHealthStore(workspaceDir: config.workspaceDir);
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchBackendFactory: SqliteBackend.open,
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      indexReconciler: CanonicalIndexReconciler(
        targetPath: config.searchDbPath,
        healthStore: healthStore,
        transitionHook: (transition) async => transitions.add(transition),
      ),
      exitFn: (code) {
        exitCalled = true;
        throw _Exit(code);
      },
    );

    await wiring.wire();

    expect(exitCalled, isFalse);
    expect(transitions, isEmpty);
    expect(_storeSnapshot(config.searchDbPath), beforeStore);
    expect(evidence.readAsBytesSync(), beforeEvidence);
    final refusal = records.singleWhere(
      (record) => record.level == Level.SEVERE && record.message.contains('search.db'),
    );
    expect(refusal.message, contains('dartclaw rebuild-index'));
    expect(await wiring.memoryIndex.search('Gate rebuild fact', userId: 'owner'), isEmpty);
    expect((await wiring.memoryCorpus.readCorpus()).index.entries.single.summary, contains('Gate rebuild fact'));
    await wiring.dispose();
  });

  test('dispose closes every search and task backend', () async {
    final config = await _seedConfig(tempDir);
    final searchBackends = <DatabaseBackend>[];
    final taskBackends = <DatabaseBackend>[];
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchBackendFactory: (path) async {
        final backend = await SqliteBackend.open(path);
        searchBackends.add(backend);
        return backend;
      },
      taskBackendFactory: (_) async {
        final backend = SqliteBackend.openInMemory();
        taskBackends.add(backend);
        return backend;
      },
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();
    await wiring.dispose();
    await wiring.closeBackends();

    await _expectClosed([...searchBackends, ...taskBackends]);
  });

  test('a tasks-open failure closes the search backends', () async {
    final config = await _seedConfig(tempDir);
    final searchBackends = <DatabaseBackend>[];
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchBackendFactory: (path) async {
        final backend = await SqliteBackend.open(path);
        searchBackends.add(backend);
        return backend;
      },
      taskBackendFactory: (_) async => throw StateError('task open failed'),
      exitFn: (code) => throw _Exit(code),
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));

    await _expectClosed(searchBackends);
  });

  test('a state-open failure closes both persistent backends before exit', () async {
    final config = await _seedConfig(tempDir);
    Directory(p.join(config.server.dataDir, 'state.db')).createSync();
    final searchBackends = <DatabaseBackend>[];
    final taskBackends = <DatabaseBackend>[];
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchBackendFactory: (path) async {
        final backend = await SqliteBackend.open(path);
        searchBackends.add(backend);
        return backend;
      },
      taskBackendFactory: (_) async {
        final backend = SqliteBackend.openInMemory();
        taskBackends.add(backend);
        return backend;
      },
      exitFn: (code) => throw _Exit(code),
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));

    await _expectClosed([...searchBackends, ...taskBackends]);
  });
}

Future<DartclawConfig> _seedConfig(Directory root) async {
  final config = DartclawConfig(server: ServerConfig(dataDir: root.path));
  Directory(config.workspaceDir).createSync(recursive: true);
  await seedCanonicalMemory(
    config.workspaceDir,
    topics: const {
      'general': ['Gate rebuild fact'],
    },
  );
  return config;
}

void _createLegacySearchStore(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      CREATE TABLE memory_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        source TEXT NOT NULL,
        category TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        user_id TEXT NOT NULL DEFAULT 'owner'
      )
    ''');
    database.execute('''
      CREATE VIRTUAL TABLE memory_chunks_fts USING fts5(
        body,
        content='memory_chunks',
        content_rowid='id'
      )
    ''');
    database.execute('''
      CREATE TRIGGER memory_chunks_ai AFTER INSERT ON memory_chunks BEGIN
        INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text);
      END
    ''');
    database.execute("INSERT INTO memory_chunks (text, source) VALUES ('obsolete legacy row', 'legacy')");
  } finally {
    database.close();
  }
}

String _storeSnapshot(String path) {
  final database = sqlite3.open(path);
  try {
    final objects = database.select('''
      SELECT type, name, tbl_name, sql
      FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name
    ''');
    final data = <String, Object?>{};
    for (final row in objects.where((row) => row['type'] == 'table')) {
      final name = row['name'] as String;
      if (name.startsWith('memory_chunks_fts')) continue;
      data[name] = database.select('SELECT * FROM "$name"').map((item) => item.values.toList()).toList();
    }
    return jsonEncode({'objects': objects.map((row) => row.values.toList()).toList(), 'data': data});
  } finally {
    database.close();
  }
}

Future<void> _expectClosed(List<DatabaseBackend> backends) async {
  expect(backends, isNotEmpty);
  for (final backend in backends) {
    await expectLater(() => backend.query('SELECT 1'), throwsStateError);
  }
}

final class _CloseObserverBackend implements DatabaseBackend {
  new(this._delegate, this._onClose);

  final DatabaseBackend _delegate;
  final Future<void> Function() _onClose;

  @override
  Future<void> close() async {
    await _delegate.close();
    await _onClose();
  }

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const <Object?>[]]) => _delegate.execute(sql, parameters);

  @override
  Future<DatabaseStatement> prepare(String sql) => _delegate.prepare(sql);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const <Object?>[]]) =>
      _delegate.query(sql, parameters);

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) => _delegate.transaction(body);
}

final class _Exit implements Exception {
  const new(this.code);

  final int code;
}
