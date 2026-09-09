import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late DartclawConfig config;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('hybrid_lifecycle_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      search: const SearchConfig(backend: 'hybrid'),
    );
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'preferences': ['memoryneedle prefers tea'],
      },
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  for (final healthChange in ['none', 'degraded', 'missing', 'malformed', 'new revision']) {
    test('inspection releases results and diagnostics only for unchanged current health: $healthChange', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var queryCalls = 0;
      final diagnostics = <SearchDiagnostics>[];
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        exitFn: (code) => throw StateError('Unexpected exit $code'),
        embeddingProviderFactory: () => CallbackEmbeddingProvider(
          embedQuery: (_) async {
            queryCalls++;
            entered.complete();
            await release.future;
            return [1, 0];
          },
        ),
      );
      await wiring.wire();
      try {
        final query = wiring.inspectMemorySearch('memoryneedle', diagnostics: diagnostics.add);
        await entered.future;
        expect(diagnostics, isEmpty, reason: 'Diagnostics must remain buffered until the after-probe');
        final manifest = await wiring.memoryCorpus.manifest();
        switch (healthChange) {
          case 'degraded':
            await wiring.indexHealth.recordDegraded(
              canonicalRevision: manifest.collectionRevision,
              canonicalFingerprint: manifest.fingerprint,
              stage: 'test',
              reason: 'Injected degraded evidence',
            );
          case 'missing':
            File(wiring.indexHealth.path).deleteSync();
          case 'malformed':
            File(wiring.indexHealth.path).writeAsStringSync('malformed');
          case 'new revision':
            await wiring.memoryFile.appendDailyLog('A canonical update during inspection');
          case 'none':
            break;
        }
        release.complete();
        final result = await query;
        if (healthChange == 'none') {
          expect(result!.single.chunk, contains('memoryneedle'));
          expect(diagnostics, hasLength(1));
          expect(diagnostics.single.candidates, isNotEmpty);
        } else {
          expect(result, isNull);
          expect(diagnostics, isEmpty);
        }
        expect(queryCalls, 1);
      } finally {
        if (!release.isCompleted) release.complete();
        await wiring.dispose();
      }
    });
  }

  test('stale health before inspection prevents the query and all diagnostics', () async {
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      exitFn: (code) => throw StateError('Unexpected exit $code'),
      embeddingProviderFactory: () =>
          CallbackEmbeddingProvider(embedQuery: (_) => throw StateError('A stale index must not be queried')),
    );
    await wiring.wire();
    try {
      final manifest = await wiring.memoryCorpus.manifest();
      await wiring.indexHealth.recordDegraded(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        stage: 'test',
        reason: 'Stale before query',
      );
      final diagnostics = <SearchDiagnostics>[];
      expect(await wiring.inspectMemorySearch('memoryneedle', diagnostics: diagnostics.add), isNull);
      expect(diagnostics, isEmpty);
      expect((await wiring.searchBackend.search('memoryneedle')).results, isEmpty);
    } finally {
      await wiring.dispose();
    }
  });

  for (final disposeFails in [false, true]) {
    test('shutdown drains both mutations before provider and stores close, disposal failure=$disposeFails', () async {
      final memoryStarted = Completer<void>();
      final conversationStarted = Completer<void>();
      final release = Completer<void>();
      var holdEmbeddings = false;
      var providerDisposals = 0;
      late DatabaseBackend vectorBackend;
      late DatabaseBackend taskBackend;
      late DatabaseBackend searchBackend;
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        exitFn: (code) => throw StateError('Unexpected exit $code'),
        taskBackendFactory: (_) async => taskBackend = SqliteBackend.openInMemory(),
        searchBackendFactory: (path) async => searchBackend = await SqliteBackend.open(path),
        vectorBackendFactory: (path) async => vectorBackend = await SqliteBackend.open(path),
        embeddingProviderFactory: () => CallbackEmbeddingProvider(
          embedDocuments: (documents) async {
            if (holdEmbeddings && documents.any((text) => text.contains('pendingmemory'))) {
              memoryStarted.complete();
              await release.future;
            }
            if (holdEmbeddings && documents.any((text) => text.contains('pendingconversation'))) {
              conversationStarted.complete();
              await release.future;
            }
            return [
              for (final _ in documents) [1, 0],
            ];
          },
          dispose: () async {
            providerDisposals++;
            expect(release.isCompleted, isTrue, reason: 'The shared provider must outlive both pending mutations');
            for (final backend in [vectorBackend, taskBackend, searchBackend]) {
              expect(await backend.query('SELECT 1 AS alive'), [
                {'alive': 1},
              ]);
            }
            expect(
              await SqliteVectorIndex(vectorBackend, table: VectorTable.conversationChunks).list(userId: 'owner'),
              hasLength(1),
            );
            if (disposeFails) throw StateError('Injected provider disposal failure');
          },
        ),
      );
      await wiring.wire();
      holdEmbeddings = true;
      final memoryWrite = wiring.memoryFile.appendDailyLog('pendingmemory');
      final session = await wiring.sessions.createSession();
      final message = await wiring.messages.insertMessage(
        sessionId: session.id,
        role: 'user',
        content: 'pendingconversation',
      );
      await Future.wait([memoryStarted.future, conversationStarted.future]);
      final closing = wiring.dispose();
      final closeExpectation = disposeFails ? expectLater(closing, throwsStateError) : expectLater(closing, completes);
      await pumpEventQueue();
      expect(providerDisposals, 0);
      expect(await vectorBackend.query('SELECT 1 AS alive'), [
        {'alive': 1},
      ]);
      release.complete();
      await memoryWrite;
      await closeExpectation;
      expect(providerDisposals, 1);
      for (final backend in [vectorBackend, taskBackend, searchBackend]) {
        await expectLater(() => backend.query('SELECT 1'), throwsStateError);
      }
      final retained = await SqliteBackend.open(config.vectorsDbPath);
      try {
        final conversations = await SqliteVectorIndex(
          retained,
          table: VectorTable.conversationChunks,
        ).list(userId: 'owner');
        expect(conversations.single.documentId, message.id);
        expect(await SqliteVectorIndex(retained, table: VectorTable.memoryChunks).list(userId: 'owner'), hasLength(2));
      } finally {
        await retained.close();
      }
    });
  }
}
