import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_server/src/execution_coordinator.dart';
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

void main() {
  Future<void> verifyFailedRecoveryRelease({required bool terminationConfirmed}) async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_cancel_reuse_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: tempDir.path);
    final messages = MessageService(baseDir: tempDir.path);
    final behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test');
    final primaryHarness = FakeAgentHarness();
    final failedHarness = IdleAfterFailedCancelRecoveryHarness(terminationConfirmed: terminationConfirmed);
    final replacementHarness = FakeAgentHarness();
    final primary = TurnRunner(harness: primaryHarness, messages: messages, behavior: behavior, providerId: 'claude');
    final failedRunner = TurnRunner(
      harness: failedHarness,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final replacementRunner = TurnRunner(
      harness: replacementHarness,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final available = <TurnRunner>[failedRunner, replacementRunner];
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (_) async => available.removeAt(0),
    );
    addTearDown(coordinator.dispose);
    final turns = TurnManager.fromCoordinator(coordinator: coordinator, sessions: sessions);
    final firstSession = await sessions.createSession(type: SessionType.logicalAgent, provider: 'claude');
    final firstTurnId = await turns.startTurn(firstSession.id, const []);
    await failedHarness.turnInvoked;

    await turns.cancelTurn(firstSession.id);
    final disposed = coordinator.events.firstWhere(
      (event) => event.kind == ExecutionEventKind.disposed && identical(event.runner, failedRunner),
    );
    failedHarness.completeSuccess();
    await disposed;

    expect((await turns.waitForOutcome(firstSession.id, firstTurnId)).status, TurnStatus.cancelled);
    expect(failedHarness.state, WorkerState.stopped);
    expect(failedHarness.disposeCalled, isTrue);
    expect(coordinator.snapshot.cachedWorkers, 0);

    if (!terminationConfirmed) {
      final capacity = coordinator.snapshot.providers['claude']!;
      expect(capacity.effective, 0);
      expect(capacity.quarantined, 1);
      return;
    }

    final secondSession = await sessions.createSession(type: SessionType.logicalAgent, provider: 'claude');
    final secondTurnId = await turns.startTurn(secondSession.id, const []);
    await replacementHarness.turnInvoked;
    replacementHarness.completeSuccess();
    expect((await turns.waitForOutcome(secondSession.id, secondTurnId)).status, TurnStatus.completed);
    expect(replacementHarness.turnCallCount, 1);
    expect(failedHarness.turnCallCount, 1);
  }

  test('failed cancel recovery disposes an idle worker before another session can acquire it', () async {
    await verifyFailedRecoveryRelease(terminationConfirmed: true);
  });

  test('failed cancel recovery quarantines capacity when worker teardown is unconfirmed', () async {
    await verifyFailedRecoveryRelease(terminationConfirmed: false);
  });
}
