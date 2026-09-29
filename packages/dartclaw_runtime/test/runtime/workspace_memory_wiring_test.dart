import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WorkspaceService;
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('workspace_memory_wiring_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('owner and configured workspace corpora publish under their pinned principals', () async {
    final config = _config(root, [_agent(root, 'a'), _agent(root, 'b')]);
    await _prepare(config);
    final agentA = Directory(config.agent.definitions[0].workspace!.directory);
    final agentB = Directory(config.agent.definitions[1].workspace!.directory);
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

      final workspaceA = config.agent.definitions[0].workspace!;
      final contextA = wiring.memoryContextForWorkspace(workspaceA)!;
      final sessionA = await wiring.sessions.createSession(workspace: workspaceA);
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
    final config = _config(root, [_agent(root, 'broken')]);
    await _prepare(config);
    final invalid = Directory(config.agent.definitions.single.workspace!.directory);
    File('${invalid.path}/MEMORY.md').writeAsStringSync('## preview\n- invalid dialect\n');
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

  test('an unmarked managed home refuses before owner corpus or index activity', () async {
    final definition = _agent(root, 'blocked');
    final config = _config(root, [definition]);
    final home = Directory(p.dirname(definition.workspace!.directory))..createSync(recursive: true);
    File(p.join(home.path, 'retained.txt')).writeAsStringSync('do not adopt');
    var backendOpened = false;

    await expectLater(
      _wire(config, onBackendOpen: () => backendOpened = true),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('no identity.json'))),
    );

    expect(backendOpened, isFalse);
    expect(File(p.join(config.workspaceDir, 'MEMORY.md')).existsSync(), isFalse);
    expect(File(p.join(home.path, 'retained.txt')).readAsStringSync(), 'do not adopt');
  });

  test('a managed directory without a memory grant is admin-visible but unavailable to its agent', () async {
    final noGrant = _agent(root, 'helper', tools: const {'web_search'});
    final config = _config(root, [noGrant]);
    await _prepare(config);
    await seedCanonicalMemory(
      noGrant.workspace!.directory,
      topics: const {
        'general': ['must-not-index'],
      },
    );

    final wiring = await _wire(config);
    try {
      expect(wiring.memoryContexts.map((context) => context.principal), ['owner']);
      expect(wiring.adminMemoryContexts.map((context) => context.principal), contains('agent:helper'));
      expect(
        (await wiring.memoryIndex.search('must-not-index', userId: 'agent:helper')).single.chunk,
        'must-not-index',
      );
      final session = await wiring.sessions.createSession(workspace: noGrant.workspace);
      await expectLater(
        wiring.memoryContextForCaller(sessionId: session.id, agentId: 'helper'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('unavailable'))),
      );
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
    }
  });

  test('an empty allowlist retains the cascade default memory grant', () async {
    final defaultPolicy = _agent(root, 'generalist', tools: const {});
    final config = _config(root, [defaultPolicy]);
    await _prepare(config);

    final wiring = await _wire(config);
    try {
      final context = wiring.memoryContextForWorkspace(defaultPolicy.workspace);
      expect(context, isNotNull);
      expect(context!.allowsRead, isTrue);
      expect(context.allowsWrite, isTrue);
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
    }
  });

  test('hybrid startup reconciles memory and conversation vectors for every persisted principal', () async {
    final agent = _agent(root, 'a');
    final config = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      agent: AgentConfig(definitions: [agent]),
      search: const SearchConfig(backend: 'hybrid'),
    );
    await _prepare(config);
    final agentA = Directory(agent.workspace!.directory);
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
    final agentSession = await sessions.createSession(workspace: agent.workspace);
    await messages.insertMessage(sessionId: ownerSession.id, role: 'user', content: 'owner-conversation-vector');
    await messages.insertMessage(sessionId: agentSession.id, role: 'user', content: 'agent-conversation-vector');
    await messages.dispose();

    final vectorBackend = PostgresVectorTestBackend();
    final wiring = await _wire(
      config,
      backend: vectorBackend,
      embeddingProvider: CallbackEmbeddingProvider(
        embedDocuments: (documents) async => [
          for (var index = 0; index < documents.length; index++) [1.0, index.toDouble()],
        ],
      ),
    );
    try {
      for (final principal in ['owner', 'agent:a']) {
        expect(
          await PostgresVectorIndex(vectorBackend, table: VectorTable.memoryChunks).list(userId: principal),
          isNotEmpty,
        );
        expect(
          await PostgresVectorIndex(vectorBackend, table: VectorTable.conversationChunks).list(userId: principal),
          isNotEmpty,
        );
      }
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
    }
  });
}

AgentDefinition _agent(
  Directory root,
  String id, {
  Set<String> tools = const {'memory_apply', 'memory_observe', 'memory_search', 'memory_read', 'context_research'},
}) => AgentDefinition(
  id: id,
  description: '$id fixture',
  prompt: '',
  allowedTools: tools,
  workspace: AgentWorkspace.managed(agentId: id, dataDir: root.path, ownerWorkspaceDir: p.join(root.path, 'workspace')),
);

DartclawConfig _config(Directory root, List<AgentDefinition> agents) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  agent: AgentConfig(definitions: agents),
);

Future<StorageWiring> _wire(
  DartclawConfig config, {
  DatabaseBackend? backend,
  EmbeddingProvider? embeddingProvider,
  void Function()? onBackendOpen,
}) async {
  final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
  final wiring = StorageWiring(
    config: config,
    eventBus: EventBus(),
    taskBackendFactory: (_) async {
      onBackendOpen?.call();
      return backend ?? openPreparedTaskBackend();
    },
    taskBackendIsPrepared: true,
    searchIndexFactory: (_, table, {required withinTransaction}) =>
        indices.putIfAbsent(table, InMemoryFullTextIndex.new),
    embeddingProviderFactory: embeddingProvider == null ? null : () => embeddingProvider,
    exitFn: (code) => throw StateError('unexpected exit $code'),
  );
  await wiring.wire();
  return wiring;
}

Future<void> _prepare(DartclawConfig config) =>
    WorkspaceService(dataDir: config.server.dataDir)
        .prepareManagedAgents(config.agent.definitions.map((definition) => definition.workspace!).toList());
