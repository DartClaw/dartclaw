import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late EventBus eventBus;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('memory_hybrid_lifecycle_');
    eventBus = EventBus();
  });

  tearDown(() async {
    if (!eventBus.isDisposed) await eventBus.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('incremental and complete commits reconcile vectors after lexical health', () async {
    final config = _config(root);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['retained startup memory'],
      },
    );
    final embeddedBatches = <List<String>>[];
    final wiring = await _wire(
      config,
      eventBus,
      CallbackEmbeddingProvider(
        embedDocuments: (documents) async {
          embeddedBatches.add([...documents]);
          return [
            for (final _ in documents) const [1.0, 0.0],
          ];
        },
      ),
    );
    try {
      expect(await wiring.memoryMissingVectorCount(), 0);

      await wiring.memoryFile.appendDailyLog('incremental vector lifecycle evidence');
      await _waitFor(() async => (await wiring.inspectMemorySearch('incremental'))?.isNotEmpty ?? false);
      expect(await wiring.memoryMissingVectorCount(), 0);
      final manifest = await wiring.memoryCorpus.manifest();
      final health = await wiring.indexHealth.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
      expect(health.isCurrent(manifest.collectionRevision, manifest.fingerprint), isTrue);
      expect(embeddedBatches.expand((batch) => batch), contains(contains('incremental vector lifecycle evidence')));

      final current = await wiring.memoryCorpus.readCorpus();
      final result = await wiring.memoryCorpus.commit(
        expectedRevision: current.index.metadata.revision,
        replacement: CanonicalMemoryCorpus(index: MemoryIndexDocument(metadata: current.index.metadata)),
      );
      expect(result.wasCommitted, isTrue);
      expect(await wiring.memoryMissingVectorCount(), 0);
      expect(await wiring.memoryIndex.count(userId: 'owner'), 0);
    } finally {
      await _close(wiring);
    }
  });

  test('embedding failure preserves the commit, lexical rows, and healthy evidence', () async {
    final config = _config(root);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['existing memory'],
      },
    );
    final wiring = await _wire(
      config,
      eventBus,
      CallbackEmbeddingProvider(embedDocuments: (_) async => throw StateError('provider unavailable')),
    );
    try {
      await wiring.memoryFile.appendDailyLog('lexical survives vector failure');

      final corpus = await wiring.memoryCorpus.readCorpus();
      expect(corpus.observations.single.observations.single.content, 'lexical survives vector failure');
      expect(await wiring.memoryIndex.search('survives', userId: 'owner'), isNotEmpty);
      expect(await wiring.memoryMissingVectorCount(), greaterThan(0));
      final manifest = await wiring.memoryCorpus.manifest();
      final health = await wiring.indexHealth.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
      expect(health.isCurrent(manifest.collectionRevision, manifest.fingerprint), isTrue);
    } finally {
      await _close(wiring);
    }
  });
}

DartclawConfig _config(Directory root) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  search: const SearchConfig(backend: 'hybrid'),
);

Future<StorageWiring> _wire(DartclawConfig config, EventBus eventBus, EmbeddingProvider provider) async {
  final wiring = StorageWiring(
    config: config,
    eventBus: eventBus,
    searchBackendFactory: SqliteBackend.open,
    taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
    embeddingProviderFactory: () => provider,
    searchRelevanceTurn: (_, schema) async => {
      for (final key in (schema['properties'] as Map).keys) key as String: true,
    },
    exitFn: (code) => throw StateError('unexpected exit $code'),
  );
  await wiring.wire();
  return wiring;
}

Future<void> _waitFor(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached before the deadline');
}

Future<void> _close(StorageWiring wiring) async {
  await wiring.messages.dispose();
  await wiring.dispose();
}
