import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late DartclawConfig config;
  late List<String> output;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('conversation_rebuild_');
    config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    output = [];
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<void> run({bool json = false}) async {
    final runner = DartclawRunner()..addCommand(RebuildIndexCommand(config: config, writeLine: output.add));
    await runner.run(['rebuild-index', if (json) '--json']);
  }

  test('hybrid rebuild reuses retained vectors for both corpora and clears removed sources', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: dataDir.path),
      search: const SearchConfig(backend: 'hybrid'),
    );
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: {
        'preferences': ['memoryneedle prefers tea'],
      },
    );
    const sessionId = '00000000-0000-4000-8000-000000000001';
    await _writeSession(
      config,
      id: sessionId,
      type: SessionType.user,
      messages: [_message('message-1', 'user', 'conversationneedle likes coffee')],
    );
    var embeddedDocuments = 0;
    var disposals = 0;
    Future<Map<String, dynamic>> rebuild() async {
      output.clear();
      final runner = DartclawRunner()
        ..addCommand(
          RebuildIndexCommand(
            config: config,
            writeLine: output.add,
            embeddingProviderFactory: () => CallbackEmbeddingProvider(
              embedDocuments: (documents) async {
                embeddedDocuments += documents.length;
                return [
                  for (final _ in documents) [1.0, 0.0],
                ];
              },
              dispose: () async => disposals++,
            ),
          ),
        );
      await runner.run(['rebuild-index', '--json']);
      return jsonDecode(output.single) as Map<String, dynamic>;
    }

    final first = await rebuild();
    expect(first['memoryUnembeddedCount'], 0);
    expect(first['conversationUnembeddedCount'], 0);
    expect(first['vectorDegradedCorpora'], isNull);
    final initialEmbeddings = embeddedDocuments;
    expect(initialEmbeddings, greaterThan(1));
    expect(File(config.vectorsDbPath).existsSync(), isTrue);
    final vectors = await SqliteBackend.open(config.vectorsDbPath);
    final memoryBefore = await SqliteVectorIndex(vectors, table: VectorTable.memoryChunks).list(userId: 'owner');
    expect(memoryBefore, isNotEmpty);
    expect(
      (await SqliteVectorIndex(vectors, table: VectorTable.conversationChunks).list(userId: 'owner'))
          .map((row) => row.documentId),
      ['message-1'],
    );
    await vectors.close();

    final second = await rebuild();
    expect(second['memoryUnembeddedCount'], 0);
    expect(second['conversationUnembeddedCount'], 0);
    expect(embeddedDocuments, initialEmbeddings, reason: 'lexical republication must retain reusable embeddings');

    await seedCanonicalMemory(config.workspaceDir);
    await _writeSession(config, id: sessionId, type: SessionType.user, messages: []);
    final empty = await rebuild();
    expect(empty['memoryUnembeddedCount'], 0);
    expect(empty['conversationUnembeddedCount'], 0);
    final cleared = await SqliteBackend.open(config.vectorsDbPath);
    try {
      expect(await SqliteVectorIndex(cleared, table: VectorTable.memoryChunks).list(userId: 'owner'), isEmpty);
      expect(await SqliteVectorIndex(cleared, table: VectorTable.conversationChunks).list(userId: 'owner'), isEmpty);
    } finally {
      await cleared.close();
    }
    expect(embeddedDocuments, initialEmbeddings);
    expect(disposals, 3);
  });

  for (final failedBoundary in ['provider', 'vector store']) {
    test('hybrid $failedBoundary failure leaves both lexical corpora queryable with separate missing counts', () async {
      config = DartclawConfig(
        server: ServerConfig(dataDir: dataDir.path),
        search: const SearchConfig(backend: 'hybrid'),
      );
      await seedCanonicalMemory(
        config.workspaceDir,
        topics: {
          'preferences': ['memoryneedle prefers tea'],
        },
      );
      await _writeSession(
        config,
        id: '00000000-0000-4000-8000-000000000001',
        type: SessionType.user,
        messages: [_message('message-1', 'user', 'conversationneedle likes coffee')],
      );
      if (failedBoundary == 'vector store') {
        final vectors = await SqliteBackend.open(config.vectorsDbPath);
        try {
          await SqliteSchemaGate.prepareVectors(vectors, storeName: 'vectors.db');
          for (final table in ['memory_vectors', 'conversation_vectors']) {
            await vectors.execute(
              'CREATE TRIGGER refuse_$table BEFORE INSERT ON $table '
              "BEGIN SELECT RAISE(ABORT, 'injected vector insert failure'); END",
            );
          }
        } finally {
          await vectors.close();
        }
      }
      final runner = DartclawRunner()
        ..addCommand(
          RebuildIndexCommand(
            config: config,
            writeLine: output.add,
            embeddingProviderFactory: () => CallbackEmbeddingProvider(
              embedDocuments: (documents) async {
                if (failedBoundary == 'provider') throw const FileSystemException('model absent');
                return [
                  for (final _ in documents) [1.0, 0.0],
                ];
              },
            ),
          ),
        );

      await runner.run(['rebuild-index', '--json']);

      final result = jsonDecode(output.single) as Map<String, dynamic>;
      expect(result['health'], 'healthy');
      expect(result['memoryUnembeddedCount'], failedBoundary == 'provider' ? greaterThan(0) : isNull);
      expect(result['conversationUnembeddedCount'], failedBoundary == 'provider' ? equals(1) : isNull);
      expect(result['vectorDegradedCorpora'], ['memory', 'conversation']);
      final backend = await SqliteBackend.open(config.searchDbPath);
      try {
        expect(
          await SqliteFtsIndex(backend, table: SqliteFtsTable.memoryChunks).search('memoryneedle', userId: 'owner'),
          isNotEmpty,
        );
        expect(
          (await SqliteFtsIndex(
            backend,
            table: SqliteFtsTable.conversationChunks,
          ).search('conversationneedle', userId: 'owner')).map((row) => row.id),
          ['message-1'],
        );
      } finally {
        await backend.close();
      }
    });
  }

  test('rebuilds chat-facing messages from NDJSON when canonical memory is empty', () async {
    await _writeSession(
      config,
      id: '00000000-0000-4000-8000-000000000001',
      type: SessionType.user,
      messages: [
        _message('message-1', 'user', 'conversationneedle first'),
        _message('message-2', 'assistant', 'conversationneedle second'),
        _message('message-system', 'system', 'conversationneedle internal'),
      ],
      trailingMalformedLine: true,
    );
    await _writeSession(
      config,
      id: '00000000-0000-4000-8000-000000000002',
      type: SessionType.channel,
      messages: [_message('message-3', 'assistant', 'conversationneedle third')],
    );
    await _writeSession(
      config,
      id: '00000000-0000-4000-8000-000000000003',
      type: SessionType.task,
      messages: [
        _message('task-1', 'user', 'conversationneedle task'),
        _message('task-2', 'assistant', 'conversationneedle task reply'),
      ],
    );
    await _seedStaleConversation(config);

    await run();

    expect(output[2], contains('Rebuilt index: 0 entries'));
    expect(output.last, 'Rebuilt conversation index: 3 messages from 2 sessions');
    final backend = await SqliteBackend.open(config.searchDbPath);
    try {
      final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
      final hits = await index.search('conversationneedle', userId: 'owner', limit: 10);
      expect(hits.map((hit) => hit.id), unorderedEquals(['message-1', 'message-2', 'message-3']));
      expect(await index.search('staleconversation', userId: 'owner'), isEmpty);
    } finally {
      await backend.close();
    }

    output.clear();
    await run(json: true);
    expect(jsonDecode(output.single), {
      'canonicalRevision': 1,
      'indexedRows': 0,
      'health': 'healthy',
      'reconciled': false,
      'conversationMessages': 3,
      'conversationSessions': 2,
    });
  });

  test('an absent sessions directory clears stale conversation rows', () async {
    await _seedStaleConversation(config);

    await run();

    expect(output.last, 'Rebuilt conversation index: 0 messages from 0 sessions');
    final backend = await SqliteBackend.open(config.searchDbPath);
    try {
      final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
      expect(await index.count(userId: 'owner'), 0);
    } finally {
      await backend.close();
    }
  });
}

Map<String, Object?> _message(String id, String role, String content) => {
  'cursor': 0,
  'id': id,
  'sessionId': '',
  'role': role,
  'content': content,
  'metadata': null,
  'createdAt': DateTime.utc(2026, 9, 9, 12).toIso8601String(),
};

Future<void> _writeSession(
  DartclawConfig config, {
  required String id,
  required SessionType type,
  required List<Map<String, Object?>> messages,
  bool trailingMalformedLine = false,
}) async {
  final directory = Directory(p.join(config.sessionsDir, id))..createSync(recursive: true);
  final timestamp = DateTime.utc(2026, 9, 9, 12);
  File(p.join(directory.path, 'meta.json'))
      .writeAsStringSync(jsonEncode(Session(id: id, type: type, createdAt: timestamp, updatedAt: timestamp).toJson()));
  final lines = messages.map((message) => jsonEncode({...message, 'sessionId': id})).join('\n');
  File(p.join(directory.path, 'messages.ndjson'))
      .writeAsStringSync('$lines\n${trailingMalformedLine ? 'malformed\n' : ''}');
}

Future<void> _seedStaleConversation(DartclawConfig config) async {
  final backend = await SqliteBackend.open(config.searchDbPath);
  try {
    await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
    final index = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
    await index.upsert([
      SearchDocument(
        id: 'stale-message',
        chunks: const ['staleconversation row'],
        metadata: const {'session_id': 'stale-session', 'role': 'assistant'},
        timestamp: DateTime.utc(2025),
      ),
    ], userId: 'owner');
  } finally {
    await backend.close();
  }
}
