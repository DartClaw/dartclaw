import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show TurnLimitsConfig;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_runtime/src/turn_wait_status.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

/// An operator cancel restarts the worker through `cancel()`, `stop()`,
/// `start()`. For Claude only `stop()` fails the in-flight turn, so the runner
/// must record that failure as the cancelled turn it is and hand the worker
/// back; a turn that never settles holds the session lock and the lease.
void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_runner_cancel_settlement_');
    sessions = SessionService(baseDir: p.join(tempDir.path, 'sessions'));
    messages = MessageService(baseDir: p.join(tempDir.path, 'sessions'));
  });

  tearDown(() async {
    await messages.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('accepted cancel settles through the harness stop and frees the worker', () async {
    final worker = StopSettlesTurnHarness();
    addTearDown(worker.dispose);
    final runner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace')),
      sessions: sessions,
    );
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Mid tool call'},
    ]);
    await worker.turnInvoked;

    final result = await runner.cancelTurnById(
      session.id,
      turnId,
      TurnCancelReason.operatorCancel,
      enforceCanCancel: false,
    );
    await runner.waitForExecutionSettled(session.id, turnId).timeout(const Duration(seconds: 1));

    expect(result.status, TurnWaitState.cancelled);
    expect(worker.stopCalled, isTrue);
    expect((await runner.waitForOutcome(session.id, turnId)).status, TurnStatus.cancelled);
    expect(runner.isReusable, isTrue, reason: 'a settled cancel must hand the worker back for reuse');
    expect(runner.activeTurnId(session.id), isNull);
  });
}
