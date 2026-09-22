@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WorkspaceService;
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show CallbackEmbeddingProvider, InMemoryFullTextIndex, openPreparedTaskBackend, seedCanonicalMemory;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('composed storage keeps default, A, B, helper, legacy, and removed authority distinct across restart', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_isolation_');
    final agentA = _agent(root, 'a');
    final agentB = _agent(root, 'b');
    final helper = _agent(root, 'helper', tools: const {'web_search'});
    final config = _config(root, [agentA, agentB, helper]);
    await _prepare(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['owneralpha integration marker'],
      },
    );
    await seedCanonicalMemory(
      agentA.workspace!.directory,
      topics: const {
        'general': ['agentalpha integration marker'],
      },
    );
    await seedCanonicalMemory(
      agentB.workspace!.directory,
      topics: const {
        'general': ['agentbeta integration marker'],
      },
    );
    await seedCanonicalMemory(
      helper.workspace!.directory,
      topics: const {
        'general': ['helpergamma must not index'],
      },
    );
    final removedWorkspace = AgentWorkspace.managed(
      agentId: 'removed',
      dataDir: root.path,
      ownerWorkspaceDir: config.workspaceDir,
    );
    await WorkspaceService(dataDir: root.path).prepareManagedAgents([removedWorkspace]);
    await seedCanonicalMemory(
      removedWorkspace.directory,
      topics: const {
        'general': ['removedgamma workspace marker'],
      },
    );
    final removedBytes = File(p.join(removedWorkspace.directory, 'MEMORY.md')).readAsBytesSync();

    final sessions = SessionService(baseDir: config.sessionsDir);
    final messages = MessageService(baseDir: config.sessionsDir);
    final owner = await sessions.createSession();
    final a = await sessions.createSession(workspace: agentA.workspace);
    final b = await sessions.createSession(workspace: agentB.workspace);
    final helperSession = await sessions.createSession(workspace: helper.workspace);
    final legacy = await sessions.createSession();
    final removed = await sessions.createSession(workspace: removedWorkspace);
    await messages.insertMessage(sessionId: owner.id, role: 'user', content: 'ownerconvunique marker');
    await messages.insertMessage(sessionId: a.id, role: 'user', content: 'agentaconvunique marker');
    await messages.insertMessage(sessionId: b.id, role: 'user', content: 'agentbconvunique marker');
    await messages.insertMessage(sessionId: helperSession.id, role: 'user', content: 'helperconvunique marker');
    await messages.insertMessage(sessionId: legacy.id, role: 'user', content: 'legacyconvunique marker');
    await messages.insertMessage(sessionId: removed.id, role: 'user', content: 'removedconvunique marker');
    const excludedId = '99999999-9999-4999-8999-999999999999';
    final excludedAt = DateTime.utc(2026, 9, 14);
    await messages.insertMessageWithIdentity(
      sessionId: a.id,
      messageId: excludedId,
      role: 'user',
      content: 'retentionineligibleunique marker',
      createdAt: excludedAt,
      notifyObserver: false,
    );
    await sessions.updateConversationState(
      a.id,
      ConversationState().put(
        ConversationSubmissionClaim(
          submissionId: 'excluded-submission',
          revisionId: 'excluded-revision',
          messageId: excludedId,
          queueId: 'excluded-queue',
          payloadDigest: 'sha256:excluded',
          message: 'retentionineligibleunique marker',
          commitState: SubmissionCommitState.committed,
          workState: ConversationWorkState.queued,
          createdAt: excludedAt,
          updatedAt: excludedAt,
        ),
      ),
    );
    await messages.dispose();

    Future<void> verify(StorageWiring wiring) async {
      expect(wiring.memoryContexts.map((context) => context.principal).toSet(), {'owner', 'agent:a', 'agent:b'});
      final memoryEvidence = {'owner': 'owneralpha', 'agent:a': 'agentalpha', 'agent:b': 'agentbeta'};
      for (final evidence in memoryEvidence.entries) {
        expect(
          (await wiring.memoryIndex.search(evidence.value, userId: evidence.key)).single.chunk,
          contains(evidence.value),
        );
        for (final forbidden in memoryEvidence.keys.where((principal) => principal != evidence.key)) {
          expect(await wiring.memoryIndex.search(evidence.value, userId: forbidden), isEmpty);
        }
      }
      expect(await wiring.memoryIndex.search('helpergamma', userId: 'agent:helper'), isEmpty);
      expect(await wiring.memoryIndex.search('removedgamma', userId: 'agent:removed'), isEmpty);
      expect(
        (await wiring.conversationIndex.search('ownerconvunique', userId: 'owner')).single.chunk,
        'ownerconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('legacyconvunique', userId: 'owner')).single.chunk,
        'legacyconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('agentaconvunique', userId: 'agent:a')).single.chunk,
        'agentaconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('agentbconvunique', userId: 'agent:b')).single.chunk,
        'agentbconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('helperconvunique', userId: 'agent:helper')).single.chunk,
        'helperconvunique marker',
      );
      expect(
        (await wiring.conversationIndex.search('removedconvunique', userId: 'agent:removed')).single.chunk,
        'removedconvunique marker',
      );
      expect(await wiring.conversationIndex.search('agentaconvunique', userId: 'agent:b'), isEmpty);
      expect(await wiring.conversationIndex.search('retentionineligibleunique', userId: 'agent:a'), isEmpty);

      final contextA = await wiring.memoryContextForCaller(sessionId: a.id, agentId: 'a');
      final contextB = await wiring.memoryContextForCaller(sessionId: b.id, agentId: 'b');
      expect(wiring.memoryContextForWorkspace(agentA.workspace), same(contextA));
      expect(wiring.memoryContextForWorkspace(agentB.workspace), same(contextB));
      await contextA.file.appendDailyLog('agentdailyalpha marker');
      expect(await wiring.memoryIndex.search('agentdailyalpha', userId: 'agent:a'), isNotEmpty);
      expect(await wiring.memoryIndex.search('agentdailyalpha', userId: 'owner'), isEmpty);
      expect(await wiring.memoryIndex.search('agentdailyalpha', userId: 'agent:b'), isEmpty);
      await expectLater(
        wiring.memoryContextForCaller(sessionId: a.id, agentId: 'b'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('does not match'))),
      );
      await expectLater(
        wiring.memoryContextForCaller(sessionId: helperSession.id, agentId: 'helper'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('unavailable'))),
      );
      await expectLater(
        wiring.memoryContextForCaller(sessionId: removed.id, agentId: 'removed'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('unavailable'))),
      );
      expect(await wiring.memoryContextForCaller(sessionId: legacy.id, agentId: null), same(wiring.ownerMemoryContext));
    }

    final first = _wiring(config);
    try {
      await first.wire();
      await verify(first);
    } finally {
      await first.messages.dispose();
      await first.dispose();
    }
    final restarted = _wiring(config);
    try {
      await restarted.wire();
      await verify(restarted);
      expect(File(p.join(removedWorkspace.directory, 'MEMORY.md')).readAsBytesSync(), removedBytes);
    } finally {
      await restarted.messages.dispose();
      await restarted.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test('one failed corpus job does not substitute owner or sibling authority', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_failure_');
    final healthy = _agent(root, 'healthy');
    final broken = _agent(root, 'broken');
    final config = _config(root, [healthy, broken]);
    await _prepare(config);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['healthyowneralpha marker'],
      },
    );
    await seedCanonicalMemory(
      healthy.workspace!.directory,
      topics: const {
        'general': ['healthyagentalpha marker'],
      },
    );
    File(p.join(broken.workspace!.directory, 'MEMORY.md')).writeAsStringSync('## invalid\n- preview dialect\n');
    final wiring = _wiring(config);
    try {
      await wiring.wire();
      expect(wiring.memoryContexts.map((context) => context.principal).toSet(), {'owner', 'agent:healthy'});
      expect((await wiring.memoryIndex.search('healthyowneralpha', userId: 'owner')).single.chunk, contains('owner'));
      expect(
        (await wiring.memoryIndex.search('healthyagentalpha', userId: 'agent:healthy')).single.chunk,
        contains('agent'),
      );
      expect(await wiring.memoryIndex.search('preview', userId: 'agent:broken'), isEmpty);
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test('unmarked cutover refuses before storage activity and preserves retained bytes', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_cutover_');
    final blocked = _agent(root, 'blocked');
    final config = _config(root, [blocked]);
    final home = Directory(p.dirname(blocked.workspace!.directory))..createSync(recursive: true);
    final retained = File(p.join(home.path, 'retained.txt'))..writeAsStringSync('retained bytes');
    var backendOpened = false;
    final wiring = _wiring(config, onBackendOpen: () => backendOpened = true);

    await expectLater(
      wiring.wire(),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('no identity.json'))),
    );

    expect(backendOpened, isFalse);
    expect(retained.readAsStringSync(), 'retained bytes');
    expect(File(p.join(config.workspaceDir, 'MEMORY.md')).existsSync(), isFalse);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
}

AgentDefinition _agent(
  Directory root,
  String id, {
  Set<String> tools = const {'memory_apply', 'memory_observe', 'memory_search', 'memory_read', 'context_research'},
}) => AgentDefinition(
  id: id,
  description: id,
  prompt: id,
  allowedTools: tools,
  workspace: AgentWorkspace.managed(agentId: id, dataDir: root.path, ownerWorkspaceDir: p.join(root.path, 'workspace')),
);

DartclawConfig _config(Directory root, List<AgentDefinition> agents) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  search: const SearchConfig(backend: 'hybrid'),
  agent: AgentConfig(definitions: agents),
);

Future<void> _prepare(DartclawConfig config) =>
    WorkspaceService(dataDir: config.server.dataDir)
        .prepareManagedAgents(config.agent.definitions.map((definition) => definition.workspace!).toList());

StorageWiring _wiring(DartclawConfig config, {void Function()? onBackendOpen}) {
  final indices = <PostgresFtsTable, InMemoryFullTextIndex>{};
  return StorageWiring(
    config: config,
    eventBus: EventBus(),
    taskBackendFactory: (_) async {
      onBackendOpen?.call();
      return openPreparedTaskBackend();
    },
    taskBackendIsPrepared: true,
    searchIndexFactory: (_, table, {required withinTransaction}) =>
        indices.putIfAbsent(table, InMemoryFullTextIndex.new),
    embeddingProviderFactory: () => CallbackEmbeddingProvider(
      embedDocuments: (documents) async => [
        for (var index = 0; index < documents.length; index++) [1.0, index.toDouble()],
      ],
    ),
    exitFn: (code) => throw StateError('unexpected exit $code'),
  );
}
