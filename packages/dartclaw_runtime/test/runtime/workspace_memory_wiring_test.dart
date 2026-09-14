import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CallbackEmbeddingProvider, seedCanonicalMemory;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('workspace_memory_wiring_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('owner and configured workspace corpora publish under their pinned principals', () async {
    final agentA = Directory('${root.path}/agent-a')..createSync(recursive: true);
    final agentB = Directory('${root.path}/agent-b')..createSync(recursive: true);
    final config = _config(root, [_agent('a', agentA.path), _agent('b', agentB.path)]);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['owner-only-marker'],
      },
    );
    await seedCanonicalMemory(
      agentA.path,
      topics: const {
        'general': ['agent-a-only-marker'],
      },
    );
    await seedCanonicalMemory(
      agentB.path,
      topics: const {
        'general': ['agent-b-only-marker'],
      },
    );

    final wiring = await _wire(config);
    try {
      expect(wiring.memoryContexts.map((context) => context.principal).toSet(), {'owner', 'agent:a', 'agent:b'});
      expect((await wiring.memoryIndex.search('marker', userId: 'owner')).single.chunk, contains('owner-only-marker'));
      expect(
        (await wiring.memoryIndex.search('marker', userId: 'agent:a')).single.chunk,
        contains('agent-a-only-marker'),
      );
      expect(
        (await wiring.memoryIndex.search('marker', userId: 'agent:b')).single.chunk,
        contains('agent-b-only-marker'),
      );

      final contextA = wiring.memoryContextForWorkspace(_agent('a', agentA.path).workspace)!;
      final sessionA = await wiring.sessions.createSession(workspace: _agent('a', agentA.path).workspace);
      expect(await wiring.memoryContextForCaller(sessionId: sessionA.id, agentId: 'a'), same(contextA));
      await expectLater(
        wiring.memoryContextForCaller(sessionId: sessionA.id, agentId: null),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('does not match'))),
      );
      await expectLater(
        wiring.memoryContextForCaller(sessionId: sessionA.id, agentId: 'cron:forged'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('does not match'))),
      );
      expect(
        await wiring.memoryContextForCaller(
          sessionId: sessionA.id,
          agentId: 'cron:memory-journal:a',
          callerKind: MemoryCallerKind.scheduled,
        ),
        same(contextA),
      );
      final ownerSession = await wiring.sessions.createSession();
      await expectLater(
        wiring.memoryContextForCaller(sessionId: ownerSession.id, agentId: 'cron:forged'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('no pinned'))),
      );
      expect(
        await wiring.memoryContextForCaller(
          sessionId: ownerSession.id,
          agentId: 'cron:memory-journal',
          callerKind: MemoryCallerKind.scheduled,
        ),
        same(wiring.ownerMemoryContext),
      );
      await contextA.file.appendDailyLog('agent-a-incremental-marker');
      expect(
        (await wiring.memoryIndex.search('incremental', userId: 'agent:a')).single.chunk,
        contains('agent-a-incremental-marker'),
      );
      expect(await wiring.memoryIndex.search('incremental', userId: 'owner'), isEmpty);
      expect(await wiring.memoryIndex.search('incremental', userId: 'agent:b'), isEmpty);
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
    }
  });

  test('one invalid configured corpus stays unavailable without replacing owner memory', () async {
    final invalid = Directory('${root.path}/invalid-agent')..createSync(recursive: true);
    File('${invalid.path}/MEMORY.md').writeAsStringSync('## preview\n- invalid dialect\n');
    final config = _config(root, [_agent('broken', invalid.path)]);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['healthy-owner-marker'],
      },
    );

    final wiring = await _wire(config);
    try {
      expect(wiring.memoryContexts.map((context) => context.principal), ['owner']);
      expect((await wiring.memoryIndex.search('healthy owner', userId: 'owner')).single.chunk, contains('marker'));
      await expectLater(
        wiring.memoryContextForCaller(sessionId: null, agentId: 'broken'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('pinned session'))),
      );
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
    }
  });

  test('hybrid startup reconciles memory and conversation vectors for every persisted principal', () async {
    final agentA = Directory('${root.path}/agent-a')..createSync(recursive: true);
    final config = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      agent: AgentConfig(definitions: [_agent('a', agentA.path)]),
      search: const SearchConfig(backend: 'hybrid'),
    );
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['owner-vector-marker'],
      },
    );
    await seedCanonicalMemory(
      agentA.path,
      topics: const {
        'general': ['agent-vector-marker'],
      },
    );
    final sessions = SessionService(baseDir: config.sessionsDir);
    final messages = MessageService(baseDir: config.sessionsDir);
    final ownerSession = await sessions.createSession();
    final agentSession = await sessions.createSession(workspace: _agent('a', agentA.path).workspace);
    await messages.insertMessage(sessionId: ownerSession.id, role: 'user', content: 'owner-conversation-vector');
    await messages.insertMessage(sessionId: agentSession.id, role: 'user', content: 'agent-conversation-vector');
    await messages.dispose();

    final wiring = await _wire(
      config,
      embeddingProvider: CallbackEmbeddingProvider(
        embedDocuments: (documents) async => [
          for (var index = 0; index < documents.length; index++) [1.0, index.toDouble()],
        ],
      ),
    );
    try {
      final vectors = await SqliteBackend.open(config.vectorsDbPath);
      try {
        for (final principal in ['owner', 'agent:a']) {
          expect(await SqliteVectorIndex(vectors, table: VectorTable.memoryChunks).list(userId: principal), isNotEmpty);
          expect(
            await SqliteVectorIndex(vectors, table: VectorTable.conversationChunks).list(userId: principal),
            isNotEmpty,
          );
        }
      } finally {
        await vectors.close();
      }
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
    }
  });
}

AgentDefinition _agent(String id, String directory) => AgentDefinition(
  id: id,
  description: '$id fixture',
  prompt: '',
  workspace: AgentWorkspace.pinned(agentId: id, directory: directory),
);

DartclawConfig _config(Directory root, List<AgentDefinition> agents) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  agent: AgentConfig(definitions: agents),
);

Future<StorageWiring> _wire(DartclawConfig config, {EmbeddingProvider? embeddingProvider}) async {
  final wiring = StorageWiring(
    config: config,
    eventBus: EventBus(),
    searchBackendFactory: SqliteBackend.open,
    taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
    embeddingProviderFactory: embeddingProvider == null ? null : () => embeddingProvider,
    exitFn: (code) => throw StateError('unexpected exit $code'),
  );
  await wiring.wire();
  return wiring;
}
