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
  late Map<PostgresFtsTable, InMemoryIndexRebuildTarget> lexicalIndexes;
  late Map<VectorTable, _TestVectorIndex> vectorIndexes;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('conversation_rebuild_');
    config = DartclawConfig(server: ServerConfig(dataDir: dataDir.path));
    output = [];
    lexicalIndexes = {
      PostgresFtsTable.memoryChunks: InMemoryIndexRebuildTarget(),
      PostgresFtsTable.conversationChunks: InMemoryIndexRebuildTarget(),
    };
    vectorIndexes = {VectorTable.memoryChunks: _TestVectorIndex(), VectorTable.conversationChunks: _TestVectorIndex()};
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  RebuildIndexCommand command({EmbeddingProvider Function()? embeddingProviderFactory}) => RebuildIndexCommand(
    config: config,
    writeLine: output.add,
    exitFn: (code) => throw StateError('unexpected rebuild-index exit $code: $output'),
    taskBackendFactory: (_) => openPreparedTaskBackend(),
    taskBackendIsPrepared: true,
    embeddingProviderFactory: embeddingProviderFactory,
    indexFactory: (_, table) => lexicalIndexes[table]!.index,
    rebuildTargetFactory: (_, table) => lexicalIndexes[table]!,
    vectorIndexFactory: (_, table) => vectorIndexes[table]!,
  );

  Future<void> run({bool json = false}) async {
    final runner = DartclawRunner()..addCommand(command());
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
          command(
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
    final memoryBefore = await vectorIndexes[VectorTable.memoryChunks]!.list(userId: 'owner');
    expect(memoryBefore, isNotEmpty);
    expect((await vectorIndexes[VectorTable.conversationChunks]!.list(userId: 'owner')).map((row) => row.documentId), [
      'message-1',
    ]);

    final second = await rebuild();
    expect(second['memoryUnembeddedCount'], 0);
    expect(second['conversationUnembeddedCount'], 0);
    expect(embeddedDocuments, initialEmbeddings, reason: 'lexical republication must retain reusable embeddings');

    await seedCanonicalMemory(config.workspaceDir);
    await _writeSession(config, id: sessionId, type: SessionType.user, messages: []);
    final empty = await rebuild();
    expect(empty['memoryUnembeddedCount'], 0);
    expect(empty['conversationUnembeddedCount'], 0);
    expect(await vectorIndexes[VectorTable.memoryChunks]!.list(userId: 'owner'), isEmpty);
    expect(await vectorIndexes[VectorTable.conversationChunks]!.list(userId: 'owner'), isEmpty);
    expect(embeddedDocuments, initialEmbeddings);
    expect(disposals, 3);
  });

  test('hybrid rebuild reconciles conversation vectors for a removed persisted principal', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: dataDir.path),
      search: const SearchConfig(backend: 'hybrid'),
    );
    await seedCanonicalMemory(config.workspaceDir);
    final removedWorkspace = AgentWorkspace.pinned(agentId: 'removed', directory: p.join(dataDir.path, 'removed'));
    const sessionId = '00000000-0000-4000-8000-000000000002';
    await _writeSession(
      config,
      id: sessionId,
      type: SessionType.user,
      workspace: removedWorkspace,
      messages: [_message('removed-message', 'assistant', 'removed principal conversation')],
    );
    Future<void> rebuild() async {
      output.clear();
      final runner = DartclawRunner()
        ..addCommand(
          command(
            embeddingProviderFactory: () => CallbackEmbeddingProvider(
              embedDocuments: (documents) async => [
                for (final _ in documents) [1.0, 0.0],
              ],
            ),
          ),
        );
      await runner.run(['rebuild-index', '--json']);
    }

    await rebuild();
    expect(
      (await vectorIndexes[VectorTable.conversationChunks]!.list(userId: 'agent:removed')).map((row) => row.documentId),
      ['removed-message'],
    );
    expect(await vectorIndexes[VectorTable.memoryChunks]!.list(userId: 'agent:removed'), isEmpty);

    await _writeSession(config, id: sessionId, type: SessionType.user, workspace: removedWorkspace, messages: []);
    await rebuild();
    expect(await vectorIndexes[VectorTable.conversationChunks]!.list(userId: 'agent:removed'), isEmpty);
    expect(await lexicalIndexes[PostgresFtsTable.conversationChunks]!.index.count(userId: 'agent:removed'), 0);
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
        for (final index in vectorIndexes.values) {
          index.failReplace = true;
        }
      }
      final runner = DartclawRunner()
        ..addCommand(
          command(
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
      expect(
        await lexicalIndexes[PostgresFtsTable.memoryChunks]!.index.search('memoryneedle', userId: 'owner'),
        isNotEmpty,
      );
      expect(
        (await lexicalIndexes[PostgresFtsTable.conversationChunks]!.index.search(
          'conversationneedle',
          userId: 'owner',
        )).map((row) => row.id),
        ['message-1'],
      );
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
    await lexicalIndexes[PostgresFtsTable.conversationChunks]!.index.upsert([_staleConversation], userId: 'owner');

    await run();

    expect(output[2], contains('Rebuilt index: 0 entries'));
    expect(output.last, 'Rebuilt conversation index: 3 messages from 2 sessions');
    final index = lexicalIndexes[PostgresFtsTable.conversationChunks]!.index;
    final hits = await index.search('conversationneedle', userId: 'owner', limit: 10);
    expect(hits.map((hit) => hit.id), unorderedEquals(['message-1', 'message-2', 'message-3']));
    expect(await index.search('staleconversation', userId: 'owner'), isEmpty);

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
    await lexicalIndexes[PostgresFtsTable.conversationChunks]!.index.upsert([_staleConversation], userId: 'owner');

    await run();

    expect(output.last, 'Rebuilt conversation index: 0 messages from 0 sessions');
    expect(await lexicalIndexes[PostgresFtsTable.conversationChunks]!.index.count(userId: 'owner'), 0);
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
  AgentWorkspace? workspace,
  bool trailingMalformedLine = false,
}) async {
  final directory = Directory(p.join(config.sessionsDir, id))..createSync(recursive: true);
  final timestamp = DateTime.utc(2026, 9, 9, 12);
  File(p.join(directory.path, 'meta.json')).writeAsStringSync(
    jsonEncode(Session(id: id, type: type, workspace: workspace, createdAt: timestamp, updatedAt: timestamp).toJson()),
  );
  final lines = messages.map((message) => jsonEncode({...message, 'sessionId': id})).join('\n');
  File(p.join(directory.path, 'messages.ndjson'))
      .writeAsStringSync('$lines\n${trailingMalformedLine ? 'malformed\n' : ''}');
}

final _staleConversation = SearchDocument(
  id: 'stale-message',
  chunks: const ['staleconversation row'],
  metadata: const {'session_id': 'stale-session', 'role': 'assistant'},
  timestamp: DateTime.utc(2025),
);

final class _TestVectorIndex implements VectorIndex {
  final Map<String, Map<VectorIdentity, VectorRecord>> _records = {};
  bool failReplace = false;

  @override
  Future<List<VectorRecord>> list({required String userId}) async {
    final records = (_records[userId]?.values ?? const <VectorRecord>[]).toList();
    records.sort((left, right) {
      final byDocument = left.documentId.compareTo(right.documentId);
      return byDocument != 0 ? byDocument : left.chunkIndex.compareTo(right.chunkIndex);
    });
    return records;
  }

  @override
  Future<void> upsert(
    Iterable<VectorRecord> records, {
    required String userId,
    Set<VectorIdentity> retire = const {},
  }) async {
    final stored = _records.putIfAbsent(userId, () => {});
    for (final identity in retire) {
      stored.remove(identity);
    }
    for (final record in records) {
      stored[VectorIdentity(documentId: record.documentId, chunkIndex: record.chunkIndex)] = record;
    }
  }

  @override
  Future<void> delete(Iterable<VectorIdentity> identities, {required String userId}) async {
    for (final identity in identities) {
      _records[userId]?.remove(identity);
    }
  }

  @override
  Future<void> replaceAll(Iterable<VectorRecord> records, {required String userId}) async {
    if (failReplace) throw Exception('injected vector replacement failure');
    _records[userId] = {
      for (final record in records)
        VectorIdentity(documentId: record.documentId, chunkIndex: record.chunkIndex): record,
    };
  }

  @override
  Future<List<VectorMatch>> search(
    List<double> queryVector, {
    required String userId,
    required String modelFingerprint,
    int limit = 20,
  }) async => throw UnimplementedError('search is outside rebuild command coverage');
}
