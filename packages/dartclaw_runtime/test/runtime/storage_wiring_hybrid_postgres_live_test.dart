@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:test/test.dart';

import '../../../dartclaw_core/test/storage/postgres_live_support.dart';

void main() {
  test('PostgreSQL hybrid wiring activates both vector corpora on one backend', () async {
    await withPostgresBackend((backend, _) async {
      final dataDir = Directory.systemTemp.createTempSync('postgres_hybrid_wiring_');
      final config = DartclawConfig(
        server: ServerConfig(dataDir: dataDir.path),
        database: const DatabaseConfig(backend: DatabaseBackendKind.postgres),
        search: const SearchConfig(backend: 'hybrid'),
      );
      await seedCanonicalMemory(
        config.workspaceDir,
        topics: const {
          'preferences': ['memoryneedle prefers tea'],
        },
      );
      final session = await SessionService(baseDir: config.sessionsDir).createSession();
      final messages = MessageService(baseDir: config.sessionsDir);
      final message = await messages.insertMessage(
        sessionId: session.id,
        role: 'user',
        content: 'conversationneedle prefers coffee',
      );
      await messages.dispose();

      var taskFactoryCalls = 0;
      var providers = 0;
      var vectorFactoryCalls = 0;
      var searchFactoryCalls = 0;
      var providerDisposals = 0;
      var judgments = 0;
      final wiring = StorageWiring(
        config: config,
        eventBus: EventBus(),
        taskBackendFactory: (_) async {
          taskFactoryCalls++;
          return backend;
        },
        vectorBackendFactory: (_) async {
          vectorFactoryCalls++;
          return backend;
        },
        searchBackendFactory: (_) async {
          searchFactoryCalls++;
          throw StateError('PostgreSQL hybrid search must not open SQLite search storage');
        },
        embeddingProviderFactory: () {
          providers++;
          return CallbackEmbeddingProvider(dispose: () async => providerDisposals++);
        },
        searchRelevanceTurn: (_, schema) async {
          judgments++;
          return {for (final key in (schema['properties'] as Map).keys) key as String: true};
        },
        exitFn: (code) => throw StateError('Unexpected exit $code'),
      );
      try {
        await wiring.wire();

        expect(judgments, 0);
        expect(vectorFactoryCalls, 0);
        expect(taskFactoryCalls, 1);
        expect(providers, 1);
        expect(searchFactoryCalls, 0);
        expect(await wiring.memoryMissingVectorCount(), 0);
        expect(await wiring.conversationMissingVectorCount(), 0);
        final memoryHits = await wiring.inspectMemorySearch('memoryneedle');
        expect(memoryHits!.single.chunk, contains('memoryneedle'));
        expect((await wiring.conversationSearch.search('conversationneedle')).single.messageId, message.id);
        expect(judgments, 2, reason: 'both PostgreSQL corpora must use the injected relevance turn');

        final memoryRows = await PostgresVectorIndex(backend, table: VectorTable.memoryChunks).list(userId: 'owner');
        final conversationRows = await PostgresVectorIndex(
          backend,
          table: VectorTable.conversationChunks,
        ).list(userId: 'owner');
        expect(memoryRows.map((row) => row.documentId), [memoryHits.single.id]);
        expect(conversationRows.map((row) => row.documentId), [message.id]);
        expect(File(config.dartclawDbPath).existsSync(), isFalse);
        expect(File(config.searchDbPath).existsSync(), isFalse);
        expect(File(config.vectorsDbPath).existsSync(), isFalse);
      } finally {
        await wiring.dispose();
        expect(providerDisposals, 1);
        await expectLater(() => backend.query('SELECT 1'), throwsStateError);
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      }
    });
  });
}
