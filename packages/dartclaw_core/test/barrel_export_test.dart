/// Barrel export surface test — verifies that the public API contract holds.
///
/// Every symbol in the `show` clauses is importable and usable. Sealed class
/// subtypes are accessible via pattern matching even when only the base type
/// appears in the `show` clause.
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('barrel exports — sealed class accessibility', () {
    test('BridgeEvent sealed subtypes accessible via pattern matching', () {
      final BridgeEvent delta = DeltaEvent('hello');
      final BridgeEvent toolUse = ToolUseEvent(toolName: 'bash', toolId: 't1', input: {});
      final BridgeEvent toolResult = ToolResultEvent(toolId: 't1', output: 'ok', isError: false);
      final BridgeEvent init = SystemInitEvent(contextWindow: 200000);

      // Pattern matching works — exhaustive switch
      final matched = switch (delta) {
        DeltaEvent(:final text) => text,
        ToolUseEvent() => 'tool',
        ToolResultEvent() => 'result',
        SystemInitEvent() => 'init',
      };
      expect(matched, 'hello');

      // Type checks work
      expect(delta, isA<DeltaEvent>());
      expect(toolUse, isA<ToolUseEvent>());
      expect(toolResult, isA<ToolResultEvent>());
      expect(init, isA<SystemInitEvent>());
    });

    test('GuardVerdict sealed subtypes accessible via factories', () {
      final GuardVerdict pass = GuardVerdict.pass();
      final GuardVerdict warn = GuardVerdict.warn('caution');
      final GuardVerdict block = GuardVerdict.block('denied');

      expect(pass.isPass, isTrue);
      expect(warn.isWarn, isTrue);
      expect(warn.message, 'caution');
      expect(block.isBlock, isTrue);
      expect(block.message, 'denied');
    });
  });

  group('barrel exports — key symbols importable', () {
    test('model types constructable', () {
      final session = Session(id: 'test', createdAt: DateTime.now(), updatedAt: DateTime.now());
      expect(session.id, 'test');
      expect(session.type, SessionType.user);

      final msg = Message(
        cursor: 0,
        id: 'm1',
        sessionId: 'test',
        role: 'user',
        content: 'hello',
        createdAt: DateTime.now(),
      );
      expect(msg.role, 'user');

      final chunk = MemoryChunk(id: 1, textContent: 'fact', source: 'test', createdAt: DateTime.now());
      expect(chunk.textContent, 'fact');

      const result = MemorySearchResult(text: 'fact', source: 'test', score: 0.9);
      expect(result.score, 0.9);

      final task = Task(
        id: 'task-1',
        title: 'Title',
        description: 'Description',
        type: TaskType.coding,
        status: TaskStatus.draft,
        createdAt: DateTime.now(),
      );
      expect(task.status, TaskStatus.draft);

      final artifact = TaskArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Patch',
        kind: ArtifactKind.diff,
        path: '/tmp/patch.diff',
        createdAt: DateTime.now(),
      );
      expect(artifact.kind, ArtifactKind.diff);
      expect(TaskRepository, isNotNull);
      expect(TaskService, isNotNull);

      final goal = Goal(
        id: 'goal-1',
        title: 'Ship 0.8',
        mission: 'Deliver the release safely.',
        createdAt: DateTime.now(),
      );
      expect(goal.title, 'Ship 0.8');
      expect(GoalRepository, isNotNull);
      expect(GoalService, isNotNull);
    });

    test('SessionKey constructable', () {
      final key = SessionKey(agentId: 'main', scope: 'channel', identifiers: 'wa:123');
      expect(key.agentId, 'main');
    });

    test('container symbols importable', () {
      const config = ContainerConfig(enabled: true);
      const profile = SecurityProfile.restricted;
      expect(config.enabled, isTrue);
      expect(ContainerManager, isNotNull);
      expect(CredentialProxy, isNotNull);
      expect(profile.id, 'restricted');
    });

    test('channel provider and shared channel symbols importable', () {
      final ChannelConfigProvider provider = const DartclawConfig.defaults();
      final gating = MentionGating(requireMention: true, mentionPatterns: ['@dartclaw'], ownJid: 'wa:bot');
      final message = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'wa:user',
        groupJid: 'wa:group',
        text: 'plain message',
      );

      expect(provider, isA<ChannelConfigProvider>());
      expect(GroupAccessMode.open.name, 'open');
      expect(gating.shouldProcess(message), isFalse);
    });

    test('task trigger symbols importable', () {
      const config = TaskTriggerConfig(enabled: true);
      const parser = TaskTriggerParser();
      final result = parser.parse('task: ship it', config);
      const origin = TaskOrigin(
        channelType: 'whatsapp',
        sessionKey: 'agent:main:dm:contact:wa%3Auser',
        recipientId: 'wa:user',
      );

      expect(result, isNotNull);
      expect(result!.type, TaskType.research);
      expect(origin.recipientId, 'wa:user');
    });
  });
}
