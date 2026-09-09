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
    root = Directory.systemTemp.createTempSync('conversation_hybrid_');
    eventBus = EventBus();
  });

  tearDown(() async {
    if (!eventBus.isDisposed) await eventBus.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('append, query diagnostics, and clear share the serialized conversation owner', () async {
    final config = _config(root);
    await seedCanonicalMemory(config.workspaceDir);
    final embedded = <String>[];
    final wiring = await _wire(
      config,
      eventBus,
      CallbackEmbeddingProvider(
        embedDocuments: (documents) async {
          embedded.addAll(documents);
          return [
            for (final _ in documents) const [1.0, 0.0],
          ];
        },
      ),
    );
    try {
      final session = await wiring.sessions.createSession();
      final message = await wiring.messages.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: 'conversation hybrid provenance evidence',
      );
      await _waitFor(() async => await wiring.conversationMissingVectorCount() == 0 && embedded.isNotEmpty);

      SearchDiagnostics? diagnostics;
      final hits = await wiring.conversationSearch.search('provenance', diagnostics: (value) => diagnostics = value);
      expect(hits.map((hit) => hit.messageId), [message.id]);
      expect(hits.single.sessionId, session.id);
      expect(hits.single.role, 'assistant');
      expect(hits.single.text, 'conversation hybrid provenance evidence');
      expect(hits.single.createdAt.isUtc, isTrue);
      expect(diagnostics?.candidates.single.sourceLayer, 'conversation');

      await wiring.messages.clearMessages(session.id);
      await _waitFor(() async => await wiring.conversationMissingVectorCount() == 0);
      expect(await wiring.conversationSearch.search('provenance'), isEmpty);
    } finally {
      await _close(wiring);
    }
  });

  test('provider failure leaves appended messages and lexical fallback searchable', () async {
    final config = _config(root);
    await seedCanonicalMemory(config.workspaceDir);
    final wiring = await _wire(
      config,
      eventBus,
      CallbackEmbeddingProvider(
        embedQuery: (_) async => throw StateError('provider unavailable'),
        embedDocuments: (_) async => throw StateError('provider unavailable'),
      ),
    );
    try {
      final session = await wiring.sessions.createSession();
      final message = await wiring.messages.insertMessage(
        sessionId: session.id,
        role: 'user',
        content: 'conversation persistence survives provider failure',
      );
      await _waitFor(() async => await wiring.conversationMissingVectorCount() == 1);

      expect((await wiring.messages.getMessages(session.id)).map((item) => item.id), [message.id]);
      final hits = await wiring.conversationSearch.search('persistence');
      expect(hits.map((hit) => hit.messageId), [message.id]);
      expect(await wiring.conversationMissingVectorCount(), 1);
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
    searchRelevanceTurn: _keepAllRelevant,
    exitFn: (code) => throw StateError('unexpected exit $code'),
  );
  await wiring.wire();
  return wiring;
}

Future<Map<String, dynamic>> _keepAllRelevant(String _, Map<String, dynamic> schema) async => {
  for (final key in (schema['required'] as List).cast<String>()) key: true,
};

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
