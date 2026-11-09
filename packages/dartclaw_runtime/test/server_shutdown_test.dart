import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/server.dart' show ServerCoreDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:shelf/shelf.dart' show Request;
import 'package:test/test.dart';

import 'test_utils.dart';

/// Reports when shutdown's cancel sweep has taken its snapshot of the active turns.
class _SweepObservingTurns extends TurnManager {
  new(MessageService messages, AgentHarness worker, SessionService sessions)
    : super(
        turnLimits: const TurnLimitsConfig.defaults(),
        messages: messages,
        worker: worker,
        sessions: sessions,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );

  final Completer<void> sweepRead = Completer<void>();
  bool shuttingDown = false;

  @override
  Iterable<String> get activeSessionIds {
    if (shuttingDown && !sweepRead.isCompleted) sweepRead.complete();
    return super.activeSessionIds;
  }
}

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('a title turn reaching admission after the cancel sweep is refused, so shutdown does not wait on it', () async {
    final root = Directory.systemTemp.createTempSync('server_shutdown_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final harness = FakeAgentHarness();
    final turns = _SweepObservingTurns(messages, harness, sessions);

    // Holds the one-shot upstream of its reservation, where the sweep cannot see it. Past the gate it does what the
    // logical-agent dispatch does, on a harness that never answers: only a cancel could settle a turn started here.
    final titleDispatched = Completer<void>();
    final passSweep = Completer<void>();
    final agents = LogicalAgentSessionService(
      dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
        titleDispatched.complete();
        await passSweep.future;
        final session = await sessions.createSession();
        final turnId = await turns.reserveTurn(session.id);
        turns.executeTurn(session.id, turnId, [
          {'role': 'user', 'content': message},
        ]);
        await turns.waitForOutcome(session.id, turnId);
        return '{"title":"Late title"}';
      },
    );
    final server = composeServer(
      core: ServerCoreDeps(
        sessions: sessions,
        messages: messages,
        worker: harness,
        staticDir: await resolveStaticDir(),
        logicalAgentSessions: agents,
      ),
      turn: ServerTurnDeps(turns: turns),
    );

    final session = await sessions.createSession();
    final send = await server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/${session.id}/send'),
        headers: const {'host': 'localhost', 'content-type': 'application/json'},
        body: jsonEncode({'message': 'First message'}),
      ),
    );
    expect(send.statusCode, 200, reason: await send.readAsString());
    await harness.turnInvoked;
    harness.emit(DeltaEvent('First answer'));
    harness.completeSuccess();
    await titleDispatched.future;

    turns.shuttingDown = true;
    final shutdown = server.shutdown();
    await turns.sweepRead.future;
    passSweep.complete();

    await shutdown.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('Shutdown waited on a title turn that started after the cancel sweep.'),
    );

    expect(harness.turnCallCount, 1, reason: 'the refused title turn must never reach the provider');
    expect((await sessions.getSession(session.id))?.titleProvenance, isNot(SessionTitleProvenance.automaticGenerated));
  });
}
