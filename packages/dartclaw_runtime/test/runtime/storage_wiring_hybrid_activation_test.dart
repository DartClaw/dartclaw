import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('hybrid_activation_'));
  tearDown(() => root.deleteSync(recursive: true));

  DartclawConfig config({String backend = 'hybrid', EmbeddingConfig embedding = const EmbeddingConfig()}) =>
      DartclawConfig(
        server: ServerConfig(dataDir: root.path),
        search: SearchConfig(backend: backend, embedding: embedding),
      );

  Future<void> seed(DartclawConfig value) async {
    await seedCanonicalMemory(
      value.workspaceDir,
      topics: const {
        'preferences': ['memoryneedle prefers tea'],
      },
    );
    final session = await SessionService(baseDir: value.sessionsDir).createSession();
    final messages = MessageService(baseDir: value.sessionsDir);
    await messages.insertMessage(sessionId: session.id, role: 'user', content: 'conversationneedle prefers coffee');
    await messages.dispose();
  }

  for (final backend in ['fts5', 'qmd']) {
    test('$backend keeps lexical search without constructing vectors or a provider', () async {
      final value = config(backend: backend);
      await seed(value);
      final wiring = StorageWiring(
        config: value,
        eventBus: EventBus(),
        exitFn: (code) => throw StateError('Unexpected exit $code'),
        qmdManagerFactory: _UnavailableQmd.new,
        embeddingProviderFactory: () => throw StateError('Non-hybrid provider construction'),
        vectorBackendFactory: (_) => throw StateError('Non-hybrid vector construction'),
      );
      await wiring.wire();
      try {
        expect((await wiring.searchBackend.search('memoryneedle')).results, isNotEmpty);
        expect(await wiring.conversationSearch.search('conversationneedle'), isNotEmpty);
        expect(await wiring.memoryMissingVectorCount(), isNull);
        expect(await wiring.conversationMissingVectorCount(), isNull);
        expect(File(value.vectorsDbPath).existsSync(), isFalse);
      } finally {
        await wiring.dispose();
      }
    });
  }

  test('workflow-only storage does not activate configured hybrid retrieval', () async {
    final value = config();
    final wiring = StorageWiring(
      config: value,
      eventBus: EventBus(),
      personalMemoryEnabled: false,
      exitFn: (code) => throw StateError('Unexpected exit $code'),
      embeddingProviderFactory: () => throw StateError('Workflow-only provider construction'),
      vectorBackendFactory: (_) => throw StateError('Workflow-only vector construction'),
    );
    await wiring.wire();
    try {
      expect(await wiring.memoryMissingVectorCount(), isNull);
      expect(await wiring.conversationMissingVectorCount(), isNull);
      expect(File(value.vectorsDbPath).existsSync(), isFalse);
    } finally {
      await wiring.dispose();
    }
  });

  test('startup reuses both retained SQLite vector corpora across runtime reconstruction', () async {
    final value = config();
    await seed(value);
    var embeddings = 0;
    var providers = 0;
    var disposals = 0;
    final vectorPaths = <String>[];
    Future<void> startAndClose() async {
      final wiring = StorageWiring(
        config: value,
        eventBus: EventBus(),
        exitFn: (code) => throw StateError('Unexpected exit $code'),
        vectorBackendFactory: (path) async {
          vectorPaths.add(path);
          return SqliteBackend.open(path);
        },
        embeddingProviderFactory: () {
          providers++;
          return CallbackEmbeddingProvider(
            embedDocuments: (documents) async {
              embeddings += documents.length;
              return [
                for (final _ in documents) [1, 0],
              ];
            },
            dispose: () async => disposals++,
          );
        },
      );
      await wiring.wire();
      try {
        expect(await wiring.memoryMissingVectorCount(), 0);
        expect(await wiring.conversationMissingVectorCount(), 0);
        expect((await wiring.inspectMemorySearch('memoryneedle'))!.single.chunk, contains('memoryneedle'));
        expect(
          (await wiring.conversationSearch.search('conversationneedle')).single.text,
          contains('conversationneedle'),
        );
      } finally {
        await wiring.dispose();
      }
    }

    await startAndClose();
    final firstEmbeddings = embeddings;
    expect(firstEmbeddings, 2);
    await startAndClose();
    expect(embeddings, firstEmbeddings, reason: 'Current chunks must reuse retained vectors on startup');
    expect(providers, 2, reason: 'Each runtime shares one provider across its two corpora');
    expect(disposals, 2);
    expect(vectorPaths, [value.vectorsDbPath, value.vectorsDbPath]);
    final vectors = await SqliteBackend.open(value.vectorsDbPath);
    try {
      for (final table in [VectorTable.memoryChunks, VectorTable.conversationChunks]) {
        expect(await SqliteVectorIndex(vectors, table: table).list(userId: 'owner'), hasLength(1));
      }
    } finally {
      await vectors.close();
    }
  });

  test('a missing managed native model degrades vectors while both lexical corpora remain available', () async {
    final logs = <String>[];
    final subscription = Logger.root.onRecord.listen((record) => logs.add(record.message));
    final value = config();
    await seed(value);
    final wiring = StorageWiring(
      config: value,
      eventBus: EventBus(),
      exitFn: (code) => throw StateError('Unexpected exit $code'),
    );
    await wiring.wire();
    try {
      expect(await wiring.memoryMissingVectorCount(), 1);
      expect(await wiring.conversationMissingVectorCount(), 1);
      expect((await wiring.searchBackend.search('memoryneedle')).results, isNotEmpty);
      expect(await wiring.conversationSearch.search('conversationneedle'), isNotEmpty);
      expect(Directory('${root.path}/models').existsSync(), isFalse, reason: 'Startup must not download a model');
      expect(logs.any((message) => message.contains('dartclaw search download-model')), isTrue);
    } finally {
      await wiring.dispose();
      await subscription.cancel();
    }
  });

  test('explicit loopback HTTP activation sends only raw fixture inputs and the named API key', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final inputs = <String>[];
    final authorizations = <String?>[];
    final models = <Object?>[];
    server.listen((request) async {
      authorizations.add(request.headers.value(HttpHeaders.authorizationHeader));
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      final documents = (body['input'] as List).cast<String>();
      inputs.addAll(documents);
      models.add(body['model']);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'data': [
            for (var index = 0; index < documents.length; index++)
              {
                'index': index,
                'embedding': [1, 0],
              },
          ],
        }),
      );
      await request.response.close();
    });
    final value = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      credentials: const CredentialsConfig(entries: {'test-embedding': CredentialEntry(apiKey: 'fixture-key')}),
      search: SearchConfig(
        backend: 'hybrid',
        embedding: EmbeddingConfig(
          provider: EmbeddingProviderKind.http,
          model: 'fixture-model',
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/embeddings'),
          credential: 'test-embedding',
        ),
      ),
    );
    await seed(value);
    final wiring = StorageWiring(config: value, eventBus: EventBus(), exitFn: (code) => throw StateError('Exit $code'));
    try {
      await wiring.wire();
      expect(await wiring.memoryMissingVectorCount(), 0);
      expect(await wiring.conversationMissingVectorCount(), 0);
      await wiring.inspectMemorySearch('raw fixture query');
      expect(inputs, contains('conversationneedle prefers coffee'));
      expect(inputs, contains('raw fixture query'));
      expect(inputs.any((input) => input.contains('memoryneedle')), isTrue);
      expect(
        inputs.any((input) => input.startsWith('task: search result |') || input.startsWith('title: none |')),
        isFalse,
      );
      expect(authorizations, everyElement('Bearer fixture-key'));
      expect(models, everyElement('fixture-model'));
    } finally {
      await wiring.dispose();
      await server.close(force: true);
    }
  });

  test('missing pgvector refuses before authoritative schema preparation or provider construction', () async {
    final backend = PostgresVectorSchemaTestBackend.empty();
    final value = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      database: const DatabaseConfig(backend: DatabaseBackendKind.postgres),
      search: const SearchConfig(backend: 'hybrid'),
    );
    final wiring = StorageWiring(
      config: value,
      eventBus: EventBus(),
      taskBackendFactory: (_) async => backend,
      embeddingProviderFactory: () => throw StateError('Provider constructed before vector preflight'),
      exitFn: (code) => throw _Exit(code),
    );
    await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'exit', 1)));
    expect(backend.executed, isEmpty);
    expect(backend.transactions, 0);
    expect(backend.queries.any((query) => query.sql.contains('information_schema.tables')), isFalse);
    expect(File(value.searchDbPath).existsSync(), isFalse);
    expect(File(value.vectorsDbPath).existsSync(), isFalse);
  });
}

final class _UnavailableQmd extends QmdManager {
  new() : super(commandRunner: (_, _, {workingDirectory}) async => ProcessResult(0, 1, '', ''));

  @override
  Future<bool> isAvailable() async => false;
}

final class _Exit implements Exception {
  const new(this.code);
  final int code;
}
