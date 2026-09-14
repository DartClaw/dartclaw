import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'turn_manager_test_support.dart';

void main() {
  for (final strategy in ['append', 'replace']) {
    test('$strategy primary turns refresh canonical prompt memory while omitted scope fails closed', () async {
      final workspace = Directory.systemTemp.createTempSync('turn_prompt_memory_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final initial = _corpus(revision: 41, summary: 'revision-41-memory');
      for (final member in initial.byteInventory().entries) {
        final file = File(p.join(workspace.path, member.key))..parent.createSync(recursive: true);
        file.writeAsBytesSync(member.value);
      }
      final corpus = MemoryCorpusService(workspaceDir: workspace.path);
      addTearDown(corpus.close);
      final AgentHarness worker = strategy == 'append' ? AppendStrategyWorker() : FakeWorkerService();
      final turns = TurnManager(
        turnLimits: const TurnLimitsConfig.defaults(),
        messages: MessageService(baseDir: workspace.path),
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: workspace.path, memoryCorpus: corpus),
      );

      Future<String> run(PromptScope? scope) async {
        final turnId = await turns.startTurn(
          's1',
          const [
            {'role': 'user', 'content': 'hello'},
          ],
          isHumanInput: true,
          promptScope: scope,
        );
        await switch (worker) {
          AppendStrategyWorker() => worker.turnInvoked,
          FakeWorkerService() => worker.turnInvoked,
          _ => throw StateError('unsupported test worker'),
        };
        final prompt = switch (worker) {
          AppendStrategyWorker() => worker.lastSystemPrompt ?? '',
          FakeWorkerService() => worker.lastSystemPrompt ?? '',
          _ => throw StateError('unsupported test worker'),
        };
        switch (worker) {
          case AppendStrategyWorker():
            worker.completeSuccess();
          case FakeWorkerService():
            worker.completeSuccess();
        }
        await turns.waitForOutcome('s1', turnId);
        return prompt;
      }

      final revision41Prompt = await run(PromptScope.primary);
      expect(revision41Prompt, contains('Collection revision: 41'));
      expect(revision41Prompt, contains('revision-41-memory'));

      final committed = await corpus.commit(
        expectedRevision: 41,
        replacement: _corpus(revision: 41, summary: 'revision-42-memory'),
      );
      expect(committed.collectionRevision, 42);
      final revision42Prompt = await run(PromptScope.primary);
      expect(revision42Prompt, contains('Collection revision: 42'));
      expect(revision42Prompt, contains('revision-42-memory'));
      expect(revision42Prompt, isNot(contains('revision-41-memory')));

      for (final scope in <PromptScope?>[null, PromptScope.restricted, PromptScope.task]) {
        final failClosedPrompt = await run(scope);
        if (strategy == 'append') {
          expect(failClosedPrompt, isNotEmpty, reason: '$scope');
          expect(failClosedPrompt, contains('memory_read'), reason: '$scope');
        }
        expect(failClosedPrompt, isNot(contains('revision-42-memory')), reason: '$scope');
        expect(failClosedPrompt, isNot(contains('Collection revision:')), reason: '$scope');
      }
    });
  }

  test('daily logs select the pinned workspace and consume retention eligibility', () async {
    final root = Directory.systemTemp.createTempSync('turn_scoped_daily_log_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: p.join(root.path, 'sessions'));
    final messages = MessageService(baseDir: p.join(root.path, 'sessions'));
    addTearDown(messages.dispose);
    final ownerFile = MemoryFileService(baseDir: p.join(root.path, 'owner'));
    final agentFile = MemoryFileService(baseDir: p.join(root.path, 'agent-a'));
    addTearDown(ownerFile.dispose);
    addTearDown(agentFile.dispose);
    final worker = FakeWorkerService();
    addTearDown(worker.dispose);
    final ineligible = <String>{};
    final runner = TurnRunner(
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: p.join(root.path, 'owner')),
      memoryFile: ownerFile,
      memoryFileForSession: (session, agentName) {
        final workspace = session.workspace;
        if (workspace == null) return agentName == null || agentName == 'main' ? ownerFile : null;
        if (workspace.agentId != agentName) return null;
        return workspace.storagePrincipal == 'agent:a' ? agentFile : null;
      },
      dailyLogEligible: (session) => !ineligible.contains(session.id),
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
    );

    Future<void> run(Session session, String marker, {String agentName = 'main'}) async {
      unawaited(() async {
        await worker.turnInvoked;
        worker.emit(ToolUseEvent(toolName: 'file_read', toolId: marker, input: {'path': '$marker.md'}));
        worker.emit(DeltaEvent(marker));
        await pumpEventQueue();
        worker.completeSuccess();
      }());
      final turnId = await runner.startTurn(session.id, [
        {'role': 'user', 'content': marker},
      ], agentName: agentName);
      await runner.waitForOutcome(session.id, turnId);
    }

    final owner = await sessions.createSession();
    final agent = await sessions.createSession(
      workspace: AgentWorkspace(agentId: 'a', directory: p.join(root.path, 'agent-a')),
    );
    final missing = await sessions.createSession(
      workspace: AgentWorkspace(agentId: 'missing', directory: p.join(root.path, 'missing')),
    );
    final unconfigured = await sessions.createSession();
    final excluded = await sessions.createSession(
      workspace: AgentWorkspace(agentId: 'a', directory: p.join(root.path, 'agent-a')),
    );
    ineligible.add(excluded.id);

    await run(owner, 'owner-log');
    await run(agent, 'agent-log', agentName: 'a');
    await run(missing, 'missing-log', agentName: 'missing');
    await run(unconfigured, 'unconfigured-log', agentName: 'persona');
    await run(excluded, 'excluded-log', agentName: 'a');

    String dailyLogContent(String directory) {
      final memory = Directory(p.join(directory, 'memory'));
      if (!memory.existsSync()) return '';
      return memory.listSync().whereType<File>().map((file) => file.readAsStringSync()).join();
    }

    final ownerContent = dailyLogContent(p.join(root.path, 'owner'));
    final agentContent = dailyLogContent(p.join(root.path, 'agent-a'));
    expect(ownerContent, allOf(contains('owner-log'), isNot(contains('agent-log')), isNot(contains('missing-log'))));
    expect(agentContent, allOf(contains('agent-log'), isNot(contains('owner-log')), isNot(contains('excluded-log'))));
    expect(Directory(p.join(root.path, 'missing', 'memory')).existsSync(), isFalse);
  });
}

CanonicalMemoryCorpus _corpus({required int revision, required String summary}) {
  const collectionId = '9a56ad9e-573c-45a4-901f-4fc073a20f84';
  const entryId = 'e907c4e7-0c55-43c0-95cd-ebf41c4f6721';
  final updated = DateTime.utc(2026, 8, 12);
  final entry = CanonicalMemoryEntry(
    id: entryId,
    revision: 1,
    topic: 'preferences',
    summary: summary,
    content: 'detail',
    created: updated,
    updated: updated,
    provenance: MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: 'test'),
  );
  return CanonicalMemoryCorpus(
    index: MemoryIndexDocument(
      metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: revision),
      entries: [
        MemoryIndexEntry(
          id: entryId,
          revision: entry.revision,
          topic: entry.topic,
          summary: entry.summary,
          updated: entry.updated,
        ),
      ],
    ),
    topics: [
      MemoryTopicDocument(topic: 'preferences', entries: [entry]),
    ],
  );
}
