import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/storage/index_rebuild_target.dart' show IndexPopulateAndValidate, IndexReconcileHook;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
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

  test('canonical memory is reconciled before PostgreSQL lexical search activates', () async {
    final config = await _seedConfig(tempDir);
    final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
    final wiring = _wiring(config, indices: indices);

    await wiring.wire();
    try {
      final manifest = await wiring.memoryCorpus.manifest();
      final health = await wiring.indexHealth.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
      expect(health.isCurrent(manifest.collectionRevision, manifest.fingerprint), isTrue);
      expect((await wiring.memoryIndex.search('Gate rebuild fact', userId: 'owner')).single.chunk, contains('fact'));
      expect(indices[PostgresFtsTable.memoryChunks], same(wiring.memoryIndex));
    } finally {
      await wiring.dispose();
    }
  });

  test('reconciliation failure preserves canonical memory and publishes degraded evidence', () async {
    final config = await _seedConfig(tempDir);
    final healthStore = IndexHealthStore(workspaceDir: config.workspaceDir);
    final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
    final wiring = _wiring(
      config,
      indices: indices,
      indexReconciler: CanonicalIndexReconciler(healthStore: healthStore, target: const _FailingRebuildTarget()),
    );

    await wiring.wire();
    try {
      final corpus = await wiring.memoryCorpus.readCorpus();
      expect(corpus.index.entries.single.summary, contains('Gate rebuild fact'));
      final manifest = await wiring.memoryCorpus.manifest();
      final health = await healthStore.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
      expect(health.state, IndexHealthState.degraded);
      expect(await wiring.memoryIndex.search('Gate rebuild fact', userId: 'owner'), isEmpty);
      final outcome = await wiring.searchBackend.search('Gate rebuild fact');
      expect(outcome.results, isEmpty);
      expect(outcome.degradations.single.reason, 'indexNotCurrent');
    } finally {
      await wiring.dispose();
    }
  });

  test('dispose closes the single storage backend and remains idempotent', () async {
    final config = await _seedConfig(tempDir);
    final backend = _CloseTrackingBackend(await openPreparedTaskBackend());
    final wiring = _wiring(config, backend: backend);

    await wiring.wire();
    await wiring.dispose();
    await wiring.closeBackends();

    expect(backend.closeCalls, 1);
    await expectLater(() => backend.query('SELECT 1'), throwsStateError);
  });

  test('a task-backend open failure exits after canonical preflight', () async {
    final config = await _seedConfig(tempDir);
    final memory = File(p.join(config.workspaceDir, 'MEMORY.md'));
    var opened = false;
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      taskBackendFactory: (_) async {
        opened = true;
        expect(memory.existsSync(), isTrue);
        throw StateError('task open failed');
      },
      searchIndexFactory: (_, _, {required withinTransaction}) => InMemoryFullTextIndex(),
      exitFn: (code) => throw _Exit(code),
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));
    expect(opened, isTrue);
  });

  test('a turn-state open failure exits before the database backend opens', () async {
    final config = await _seedConfig(tempDir);
    Directory(p.join(config.server.dataDir, 'turn_state.json')).createSync();
    var opens = 0;
    final wiring = StorageWiring(
      config: config,
      eventBus: eventBus,
      taskBackendFactory: (_) async {
        opens++;
        return openPreparedTaskBackend();
      },
      taskBackendIsPrepared: true,
      searchIndexFactory: (_, _, {required withinTransaction}) => InMemoryFullTextIndex(),
      exitFn: (code) => throw _Exit(code),
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));
    expect(opens, 0);
  });
}

StorageWiring _wiring(
  DartclawConfig config, {
  DatabaseBackend? backend,
  Map<PostgresFtsTable, InMemoryFullTextIndex>? indices,
  CanonicalIndexReconciler? indexReconciler,
}) {
  final resolvedIndices = indices ?? <PostgresFtsTable, InMemoryFullTextIndex>{};
  return StorageWiring(
    config: config,
    eventBus: EventBus(),
    taskBackendFactory: (_) async => backend ?? openPreparedTaskBackend(),
    taskBackendIsPrepared: true,
    searchIndexFactory: (_, table, {required withinTransaction}) =>
        resolvedIndices.putIfAbsent(table, InMemoryFullTextIndex.new),
    indexReconciler: indexReconciler,
    exitFn: (code) => throw _Exit(code),
  );
}

Future<DartclawConfig> _seedConfig(Directory root) async {
  final config = DartclawConfig(server: ServerConfig(dataDir: root.path));
  await seedCanonicalMemory(
    config.workspaceDir,
    topics: const {
      'general': ['Gate rebuild fact'],
    },
  );
  return config;
}

final class _FailingRebuildTarget implements IndexRebuildTarget {
  const new();

  @override
  Future<bool> isPresent() async => false;

  @override
  Future<T> validateLive<T>(Future<T> Function(FullTextIndex index) body) =>
      Future.error(StateError('live index unavailable'));

  @override
  Future<T> rebuild<T>({
    required IndexPopulateAndValidate<T> populateAndValidate,
    required IndexReconcileHook transition,
  }) => Future.error(StateError('injected reconciliation failure'));
}

final class _CloseTrackingBackend implements DatabaseBackend {
  new(this.delegate);

  final DatabaseBackend delegate;
  var closeCalls = 0;
  var closed = false;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    closeCalls++;
    await delegate.close();
  }

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) {
    _ensureOpen();
    return delegate.execute(sql, parameters);
  }

  @override
  Future<DatabaseStatement> prepare(String sql) {
    _ensureOpen();
    return delegate.prepare(sql);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) {
    _ensureOpen();
    return delegate.query(sql, parameters);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    _ensureOpen();
    return delegate.transaction(body);
  }

  void _ensureOpen() {
    if (closed) throw StateError('Database backend is closed');
  }
}

final class _Exit implements Exception {
  const new(this.code);

  final int code;
}
