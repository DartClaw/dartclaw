import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('hybrid_activation_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('lexical workflow storage never probes pgvector or constructs embeddings', () async {
    final backend = PostgresVectorSchemaTestBackend.current();
    final wiring = StorageWiring(
      config: DartclawConfig(
        server: ServerConfig(dataDir: root.path),
        search: const SearchConfig(backend: 'lexical'),
      ),
      eventBus: EventBus(),
      personalMemoryEnabled: false,
      taskBackendFactory: (_) async => backend,
      embeddingProviderFactory: () => throw StateError('Lexical search constructed an embedding provider'),
      exitFn: (code) => throw _Exit(code),
    );

    await wiring.wire();
    try {
      expect(backend.queries.any((query) => query.sql.contains('pg_catalog.pg_extension')), isFalse);
      expect(backend.executed.any((sql) => sql.contains('_vectors')), isFalse);
      expect(await wiring.memoryMissingVectorCount(), isNull);
      expect(await wiring.conversationMissingVectorCount(), isNull);
    } finally {
      await wiring.dispose();
    }
  });

  test('hybrid refuses missing pgvector before schema preparation or provider construction', () async {
    final backend = PostgresVectorSchemaTestBackend.empty();
    final wiring = StorageWiring(
      config: DartclawConfig(
        server: ServerConfig(dataDir: root.path),
        search: const SearchConfig(backend: 'hybrid'),
      ),
      eventBus: EventBus(),
      taskBackendFactory: (_) async => backend,
      embeddingProviderFactory: () => throw StateError('Provider constructed before vector preflight'),
      exitFn: (code) => throw _Exit(code),
    );

    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'exit', 1)));
    expect(backend.executed, isEmpty);
    expect(backend.transactions, 0);
    expect(backend.queries.any((query) => query.sql.contains('information_schema.tables')), isFalse);
  });
}

final class _Exit implements Exception {
  const new(this.code);
  final int code;
}
