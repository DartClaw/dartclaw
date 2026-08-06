import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_server_builder_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeAgentHarness();
  });

  tearDown(() async {
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DartclawServerBuilder builderWith({GuardChain? guardChain, TaskToolFilterGuard? filter}) => DartclawServerBuilder()
    ..sessions = sessions
    ..messages = messages
    ..worker = worker
    ..behavior = BehaviorFileService(workspaceDir: tempDir.path)
    ..guardChain = guardChain
    ..taskToolFilterGuard = filter;

  group('DartclawServerBuilder.buildTurns tool policy wiring', () {
    test('a host-layered filter enforces the turn policy on the chain the harness evaluates', () async {
      // A host composes the harness chain the way serve wiring does: the base
      // security chain plus this runner's own filter.
      final base = GuardChain(guards: []);
      final filter = TaskToolFilterGuard();
      final harnessChain = GuardChain.layered(base: base, guards: [filter]);

      final turns = builderWith(guardChain: base, filter: filter).buildTurns();
      final session = await sessions.createSession();
      final turnId = await turns.startTurn(
        session.id,
        [
          {'role': 'user', 'content': 'extract facts'},
        ],
        allowedTools: const ['__knowledge_inbox_no_tools__'],
        readOnly: true,
      );
      await worker.turnInvoked;

      final midTurn = await harnessChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
      expect(midTurn.isBlock, isTrue);
      expect(midTurn.message, contains('__knowledge_inbox_no_tools__'));

      // The policy is session-scoped, not chain-wide.
      final otherSession = await harnessChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: 'other');
      expect(otherSession.isBlock, isFalse);

      worker.completeSuccess();
      await turns.waitForOutcome(session.id, turnId);

      final postTurn = await harnessChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
      expect(postTurn.isBlock, isFalse);
    });

    test('no filter is fabricated when the host does not supply one', () async {
      // A fabricated filter would never be in the injected harness's chain, so
      // the builder must not invent one and imply enforcement it cannot deliver.
      final base = GuardChain(guards: []);
      final turns = builderWith(guardChain: base).buildTurns();

      final session = await sessions.createSession();
      final turnId = await turns.startTurn(
        session.id,
        [
          {'role': 'user', 'content': 'extract facts'},
        ],
        allowedTools: const ['__knowledge_inbox_no_tools__'],
        readOnly: true,
      );
      await worker.turnInvoked;

      expect(base.guards.whereType<TaskToolFilterGuard>(), isEmpty);

      worker.completeSuccess();
      await turns.waitForOutcome(session.id, turnId);
    });
  });
}
