import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_server/src/turn_wait_status.dart';
import 'package:test/test.dart';

import 'turn_manager_test_support.dart';

void main() {
  late Directory tempDir;
  late MessageService messages;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_outcomes_test_');
    messages = MessageService(baseDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> verifyRetentionAfterWorkerDisposal({required bool unhealthy, bool resetBeforeExpiry = false}) async {
    var now = DateTime.utc(2026, 1, 1);
    const outcomeTtl = Duration(seconds: 17);
    final sessionService = SessionService(baseDir: tempDir.path);
    final session = await sessionService.createSession(type: SessionType.logicalAgent, provider: 'claude');
    final primaryWorker = FakeWorkerService();
    final pooledWorker = _DisposableWorkerService();
    final replacementWorker = _DisposableWorkerService();
    final behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test');
    final primaryRunner = TurnRunner(
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final pooledRunner = TurnRunner(
      harness: pooledWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final replacementRunner = TurnRunner(
      harness: replacementWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
      executionPolicy: const ExecutionPolicy.container('restricted'),
    );
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primaryRunner,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      createWorker: (request) async =>
          request.policy.containerProfile == 'restricted' ? replacementRunner : pooledRunner,
      outcomeTtl: outcomeTtl,
      now: () => now,
    );
    addTearDown(coordinator.dispose);
    final turns = TurnManager.fromCoordinator(coordinator: coordinator, sessions: sessionService);
    final released = coordinator.events.firstWhere(
      (event) => event.kind == ExecutionEventKind.released && event.request.sessionId == session.id,
    );

    final turnId = await turns.startTurn(session.id, []);
    await pooledWorker.turnInvoked;
    if (unhealthy) pooledWorker.workerState = WorkerState.crashed;
    pooledWorker.completeSuccess();
    final outcome = await turns.waitForOutcome(session.id, turnId);
    await released;

    if (!unhealthy) {
      final replacementLease = await coordinator.acquire(
        const ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: 'claude',
          policy: ExecutionPolicy.container('restricted'),
          sessionId: 'replacement',
        ),
      );
      replacementWorker.workerState = WorkerState.crashed;
      await replacementLease!.release();
    }

    expect(pooledWorker.disposeCalled, isTrue);
    expect(coordinator.snapshot.cachedWorkers, 0);
    expect(coordinator.runners, [same(primaryRunner)]);
    expect(turns.recentOutcome(session.id, turnId), same(outcome));
    expect(await turns.waitForOutcome(session.id, turnId), same(outcome));
    final retainedStatus = turns.turnStatus(session.id);
    expect(retainedStatus.turnId, turnId);
    expect(retainedStatus.state, TurnWaitState.completed);
    expect(retainedStatus.provider, 'claude');
    expect(sseStreamResponse(primaryWorker, turns, session.id, turnId).statusCode, 204);
    final cancel = await turns.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    expect(cancel.status, TurnWaitState.completed);
    expect(cancel.releasedSessionLock, isFalse);

    now = now.add(const Duration(seconds: 16));
    expect(turns.recentOutcome(session.id, turnId), same(outcome));
    if (resetBeforeExpiry) {
      await turns.resetSessionContinuity(session.id);
    } else {
      now = now.add(const Duration(seconds: 1));
    }
    expect(turns.recentOutcome(session.id, turnId), isNull);
    expect(turns.turnStatus(session.id).state, TurnWaitState.idle);
    await expectLater(turns.waitForOutcome(session.id, turnId), throwsArgumentError);
    await expectLater(
      turns.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel),
      throwsA(isA<TurnCancelException>().having((error) => error.code, 'code', 'TURN_NOT_FOUND')),
    );
    expect(sseStreamResponse(primaryWorker, turns, session.id, turnId).statusCode, 404);
  }

  test('retains terminal outcome after incompatible-profile replacement disposes its worker', () async {
    await verifyRetentionAfterWorkerDisposal(unhealthy: false, resetBeforeExpiry: true);
  });

  test('retains terminal outcome after unhealthy release disposes its worker', () async {
    await verifyRetentionAfterWorkerDisposal(unhealthy: true);
  });
}

final class _DisposableWorkerService extends FakeWorkerService {
  WorkerState workerState = WorkerState.idle;
  bool disposeCalled = false;

  @override
  WorkerState get state => workerState;

  @override
  Future<void> dispose() async {
    disposeCalled = true;
    await super.dispose();
  }
}
