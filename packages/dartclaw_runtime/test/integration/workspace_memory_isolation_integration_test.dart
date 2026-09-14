@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CallbackEmbeddingProvider, seedCanonicalMemory;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('owner, configured workspaces, legacy sessions, and excluded messages keep distinct durable scopes', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_isolation_');
    final agentADir = p.join(root.path, 'agent-a');
    final agentBDir = p.join(root.path, 'agent-b');
    final config = _config(root, [_agent('a', agentADir), _agent('b', agentBDir)]);
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['owner-integration-marker'],
      },
    );
    await seedCanonicalMemory(
      agentADir,
      topics: const {
        'general': ['agent-a-integration-marker'],
      },
    );
    await seedCanonicalMemory(
      agentBDir,
      topics: const {
        'general': ['agent-b-integration-marker'],
      },
    );
    final sessions = SessionService(baseDir: config.sessionsDir);
    final messages = MessageService(baseDir: config.sessionsDir);
    final legacy = await sessions.createSession();
    final agentA = await sessions.createSession(workspace: _agent('a', agentADir).workspace);
    final agentB = await sessions.createSession(workspace: _agent('b', agentBDir).workspace);
    await messages.insertMessage(sessionId: legacy.id, role: 'user', content: 'legacy-conversation-marker');
    await messages.insertMessage(sessionId: agentA.id, role: 'user', content: 'agent-a-conversation-marker');
    await messages.insertMessage(sessionId: agentB.id, role: 'user', content: 'agent-b-conversation-marker');
    const excludedId = '99999999-9999-4999-8999-999999999999';
    final excludedAt = DateTime.utc(2026, 9, 14);
    await messages.insertMessageWithIdentity(
      sessionId: agentA.id,
      messageId: excludedId,
      role: 'user',
      content: 'retention-ineligible-marker',
      createdAt: excludedAt,
      notifyObserver: false,
    );
    await sessions.updateConversationState(
      agentA.id,
      ConversationState().put(
        ConversationSubmissionClaim(
          submissionId: 'excluded-submission',
          revisionId: 'excluded-revision',
          messageId: excludedId,
          queueId: 'excluded-queue',
          payloadDigest: 'sha256:excluded',
          message: 'retention-ineligible-marker',
          commitState: SubmissionCommitState.committed,
          workState: ConversationWorkState.queued,
          createdAt: excludedAt,
          updatedAt: excludedAt,
        ),
      ),
    );
    await messages.dispose();
    final wiring = StorageWiring(
      config: config,
      eventBus: EventBus(),
      searchBackendFactory: SqliteBackend.open,
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      embeddingProviderFactory: () => CallbackEmbeddingProvider(
        embedDocuments: (documents) async => [
          for (var index = 0; index < documents.length; index++) [1.0, index.toDouble()],
        ],
      ),
      exitFn: (code) => throw StateError('unexpected exit $code'),
    );
    try {
      await wiring.wire();
      final memoryEvidence = {
        'owner': 'owner-integration-marker',
        'agent:a': 'agent-a-integration-marker',
        'agent:b': 'agent-b-integration-marker',
      };
      for (final evidence in memoryEvidence.entries) {
        expect((await wiring.memoryIndex.search(evidence.value, userId: evidence.key)).single.chunk, evidence.value);
        for (final forbidden in memoryEvidence.keys.where((principal) => principal != evidence.key)) {
          expect(await wiring.memoryIndex.search(evidence.value, userId: forbidden), isEmpty);
        }
      }
      expect(
        (await wiring.conversationIndex.search('legacy-conversation-marker', userId: 'owner')).single.chunk,
        'legacy-conversation-marker',
      );
      expect(
        (await wiring.conversationIndex.search('agent-a-conversation-marker', userId: 'agent:a')).single.chunk,
        'agent-a-conversation-marker',
      );
      expect(
        (await wiring.conversationIndex.search('agent-b-conversation-marker', userId: 'agent:b')).single.chunk,
        'agent-b-conversation-marker',
      );
      expect(await wiring.conversationIndex.search('legacy-conversation-marker', userId: 'agent:a'), isEmpty);
      expect(await wiring.conversationIndex.search('legacy-conversation-marker', userId: 'agent:b'), isEmpty);
      expect(await wiring.conversationIndex.search('retention-ineligible-marker', userId: 'agent:a'), isEmpty);

      final contextA = await wiring.memoryContextForCaller(sessionId: agentA.id, agentId: 'a');
      await contextA.file.appendDailyLog('agent-a-daily-log-marker');
      expect((await wiring.memoryIndex.search('agent-a-daily-log-marker', userId: 'agent:a')), isNotEmpty);
      expect(await wiring.memoryIndex.search('agent-a-daily-log-marker', userId: 'owner'), isEmpty);
      expect(await wiring.memoryIndex.search('agent-a-daily-log-marker', userId: 'agent:b'), isEmpty);
      final agentLog = Directory(p.join(agentADir, 'memory'))
          .listSync()
          .whereType<File>()
          .map((file) => file.readAsStringSync())
          .join();
      expect(agentLog, contains('agent-a-daily-log-marker'));
      expect(
        Directory(p.join(config.workspaceDir, 'memory'))
            .listSync()
            .whereType<File>()
            .map((file) => file.readAsStringSync())
            .join(),
        isNot(contains('agent-a-daily-log-marker')),
      );

      await expectLater(
        wiring.memoryContextForCaller(sessionId: null, agentId: 'a'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('pinned session'))),
      );
      await expectLater(
        wiring.memoryContextForCaller(sessionId: agentA.id, agentId: 'b'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('does not match'))),
      );
      await expectLater(
        wiring.memoryContextForCaller(sessionId: '00000000-0000-4000-8000-000000000000', agentId: 'a'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('unavailable'))),
      );
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });

  test('removing a configured binding launches no workspace services and leaves its files untouched', () async {
    final root = Directory.systemTemp.createTempSync('workspace_memory_removal_');
    final removedDir = p.join(root.path, 'removed');
    await seedCanonicalMemory(
      removedDir,
      topics: const {
        'general': ['removed-workspace-marker'],
      },
    );
    final markerFile = File(p.join(removedDir, 'MEMORY.md'));
    final before = markerFile.readAsBytesSync();
    final wiring = StorageWiring(
      config: _config(root, const []),
      eventBus: EventBus(),
      searchBackendFactory: SqliteBackend.open,
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      exitFn: (code) => throw StateError('unexpected exit $code'),
    );
    try {
      await wiring.wire();
      expect(wiring.memoryContexts.map((context) => context.principal), ['owner']);
      expect(await wiring.memoryIndex.search('removed-workspace-marker', userId: 'agent:removed'), isEmpty);
      expect(markerFile.readAsBytesSync(), before);
    } finally {
      await wiring.messages.dispose();
      await wiring.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });
}

AgentDefinition _agent(String id, String directory) => AgentDefinition(
  id: id,
  description: id,
  prompt: id,
  workspace: AgentWorkspace.pinned(agentId: id, directory: directory),
);

DartclawConfig _config(Directory root, List<AgentDefinition> agents) => DartclawConfig(
  server: ServerConfig(dataDir: root.path),
  search: const SearchConfig(backend: 'hybrid'),
  agent: AgentConfig(definitions: agents),
);
