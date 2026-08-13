import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_server/src/turn_wait_status.dart' show TurnCancelReason;
import 'package:test/test.dart';

import 'turn_manager_test_support.dart';
import 'execution_coordinator_test_support.dart';

void main() {
  test('channel sessions retain channel provenance on the primary lane', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_channel_surface_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessions = SessionService(baseDir: tempDir.path);
    final session = await sessions.createSession(type: SessionType.channel, channelKey: 'test:channel');
    final worker = FakeWorkerService();
    final turns = TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: tempDir.path),
      sessions: sessions,
    );
    addTearDown(turns.executions.dispose);
    final acquired = turns.executions.events.firstWhere((event) => event.kind == ExecutionEventKind.acquired);

    final turnId = await turns.startTurn(session.id, const []);
    final event = await acquired;
    expect(event.request.surface, ExecutionSurface.channel);
    expect(event.lane, ExecutionLane.primary);

    await worker.turnInvoked;
    worker.completeSuccess();
    expect((await turns.waitForOutcome(session.id, turnId)).status, TurnStatus.completed);
  });

  test('delayed worker disposal keeps second and third same-session turns serialized', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_provider_affinity_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessions = SessionService(baseDir: tempDir.path);
    final session = await sessions.createSession(type: SessionType.logicalAgent, provider: 'codex');
    final behavior = BehaviorFileService(workspaceDir: tempDir.path);
    final primaryWorker = FakeWorkerService();
    final firstWorker = _DelayedDisposeWorker();
    final replacementWorker = FakeWorkerService();
    final lockManager = SessionLockManager(maxParallel: 3);
    final primaryRunner = TurnRunner(
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      providerId: 'claude',
      lockManager: lockManager,
    );
    var createCalls = 0;
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'codex': 2},
      primary: primaryRunner,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      createWorker: (request) async {
        createCalls++;
        return TurnRunner(
          harness: createCalls == 1 ? firstWorker : replacementWorker,
          messages: messages,
          behavior: behavior,
          sessions: sessions,
          providerId: request.providerId,
          lockManager: lockManager,
        );
      },
    );
    final turns = TurnManager.fromCoordinator(coordinator: coordinator, sessions: sessions);
    addTearDown(coordinator.dispose);

    final firstTurnId = await turns.startTurn(session.id, const []);
    await firstWorker.turnInvoked;
    firstWorker.completeCrashed();
    await turns.waitForOutcome(session.id, firstTurnId);
    await firstWorker.disposeStarted.future;

    final secondTurnFuture = turns.startTurn(session.id, const []);
    var secondStarted = false;
    unawaited(secondTurnFuture.then((_) => secondStarted = true));
    await pumpEventQueue();
    expect(secondStarted, isFalse);

    firstWorker.allowDispose.complete();
    final secondTurnId = await secondTurnFuture;
    await replacementWorker.turnInvoked;
    final thirdTurnFuture = turns.startTurn(session.id, const []);
    var thirdStarted = false;
    unawaited(thirdTurnFuture.then((_) => thirdStarted = true));
    await pumpEventQueue();

    expect(createCalls, 2);
    expect(thirdStarted, isFalse);

    replacementWorker.completeSuccess();
    await turns.waitForOutcome(session.id, secondTurnId);
    final thirdTurnId = await thirdTurnFuture;
    await replacementWorker.turnInvoked;
    expect(createCalls, 2);
    expect(replacementWorker.turnCalls, 2);
    replacementWorker.completeSuccess();
    await turns.waitForOutcome(session.id, thirdTurnId);
  });

  test('logical-agent first turn provisions lazily and concurrent provider demand fails fast', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_provider_session_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessionService = SessionService(baseDir: tempDir.path);
    final session = await sessionService.createSession(type: SessionType.logicalAgent, provider: 'codex');
    final competingSession = await sessionService.createSession(type: SessionType.logicalAgent, provider: 'codex');
    final primaryWorker = FakeWorkerService();
    final codexWorker = FakeWorkerService();
    final behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test');
    final spawnGate = Completer<void>();
    final spawnStarted = Completer<void>();
    var spawnCalls = 0;
    final primaryRunner = TurnRunner(
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
      sessions: sessionService,
      providerId: 'claude',
    );
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'codex': 1},
      primary: primaryRunner,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      createWorker: (request) async {
        spawnCalls++;
        if (!spawnStarted.isCompleted) spawnStarted.complete();
        await spawnGate.future;
        return TurnRunner(
          harness: codexWorker,
          messages: messages,
          behavior: behavior,
          sessions: sessionService,
          providerId: request.providerId,
        );
      },
    );
    final providerTurns = TurnManager.fromCoordinator(coordinator: coordinator, sessions: sessionService);
    addTearDown(providerTurns.executions.dispose);

    final firstFuture = providerTurns.startTurn(session.id, []);
    await spawnStarted.future.timeout(const Duration(seconds: 1));
    expect(spawnCalls, 1);
    await expectLater(providerTurns.startTurn(competingSession.id, []), throwsA(isA<BusyTurnException>()));

    spawnGate.complete();
    final turnId = await firstFuture;
    await codexWorker.turnInvoked;
    expect(coordinator.snapshot.activeWorkers, 1);
    expect(coordinator.snapshot.availableWorkers, 0);

    codexWorker.completeSuccess();
    await providerTurns.waitForOutcome(session.id, turnId);
    await pumpEventQueue();

    expect(coordinator.snapshot.activeWorkers, 0);
    expect(coordinator.snapshot.availableWorkers, 1);
    expect(codexWorker.turnCalls, 1);
    expect(primaryWorker.turnCalls, 0);
  });

  test('provider continuity reset skips the active primary caller and clears idle workers', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_provider_reset_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessions = SessionService(baseDir: tempDir.path);
    final parentSession = await sessions.createSession();
    final logicalAgentSession = await sessions.createSession(type: SessionType.logicalAgent, provider: 'codex');
    final behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test');
    final primaryWorker = _RecordingResetWorker();
    final taskWorker = _RecordingResetWorker();
    final primaryRunner = TurnRunner(
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      providerId: 'claude',
    );
    final taskRunner = TurnRunner(
      harness: taskWorker,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      providerId: 'codex',
    );
    final turns = turnManagerForRunners([primaryRunner, taskRunner], sessions: sessions);
    addTearDown(turns.executions.dispose);
    final workerLease = await turns.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.logicalAgent,
        providerId: 'codex',
        policy: const ExecutionPolicy.host(),
        sessionId: logicalAgentSession.id,
      ),
    );
    await workerLease!.release();

    final parentTurnId = await primaryRunner.reserveTurn(parentSession.id);

    await turns.resetProviderSessionContinuity(logicalAgentSession.id);

    expect(primaryWorker.resetSessionIds, isEmpty);
    expect(taskWorker.resetSessionIds, [logicalAgentSession.id]);
    final releasedOutcome = expectLater(primaryRunner.waitForOutcome(parentSession.id, parentTurnId), throwsStateError);
    primaryRunner.releaseTurn(parentSession.id, parentTurnId);
    await releasedOutcome;
  });

  test('continuity reset fails closed when an unrelated relevant worker is busy', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_provider_busy_reset_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessions = SessionService(baseDir: tempDir.path);
    final targetSession = await sessions.createSession(type: SessionType.logicalAgent, provider: 'codex');
    final busySession = await sessions.createSession(type: SessionType.task, provider: 'codex');
    final behavior = BehaviorFileService(workspaceDir: tempDir.path);
    final primaryRunner = TurnRunner(
      harness: FakeWorkerService(),
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      providerId: 'claude',
    );
    final worker = _RecordingResetWorker();
    final workerRunner = TurnRunner(
      harness: worker,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      providerId: 'codex',
    );
    final turns = turnManagerForRunners([primaryRunner, workerRunner], sessions: sessions);
    addTearDown(turns.executions.dispose);

    final busyTurnId = await turns.startTurn(busySession.id, const []);
    await worker.turnInvoked;

    await expectLater(
      turns.resetProviderSessionContinuity(targetSession.id),
      throwsA(isA<BusyTurnException>().having((error) => error.isSameSession, 'isSameSession', isFalse)),
    );
    expect(worker.resetSessionIds, isEmpty);

    worker.completeSuccess();
    await turns.waitForOutcome(busySession.id, busyTurnId);
  });

  test('coordinated cancel keeps the lease through recovery before disposal', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_provider_cancel_settlement_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessions = SessionService(baseDir: tempDir.path);
    final session = await sessions.createSession(type: SessionType.logicalAgent, provider: 'codex');
    final behavior = BehaviorFileService(workspaceDir: tempDir.path);
    final lockManager = SessionLockManager(maxParallel: 3);
    final primaryRunner = TurnRunner(
      harness: FakeWorkerService(),
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      providerId: 'claude',
      lockManager: lockManager,
    );
    final worker = _DelayedCancelRecoveryWorker();
    late final TurnRunner workerRunner;
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'codex': 1},
      primary: primaryRunner,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      createWorker: (request) async {
        workerRunner = TurnRunner(
          harness: worker,
          messages: messages,
          behavior: behavior,
          sessions: sessions,
          providerId: request.providerId,
          lockManager: lockManager,
        );
        return workerRunner;
      },
    );
    final turns = TurnManager.fromCoordinator(coordinator: coordinator, sessions: sessions);

    final turnId = await turns.startTurn(session.id, const []);
    await worker.turnInvoked;
    final result = await workerRunner.cancelTurnById(
      session.id,
      turnId,
      TurnCancelReason.operatorCancel,
      enforceCanCancel: false,
    );
    await worker.cancelStarted.future;
    final disposeFuture = coordinator.dispose();
    await pumpEventQueue();

    expect(result.releasedSessionLock, isFalse);
    expect((await turns.waitForOutcome(session.id, turnId)).status, TurnStatus.cancelled);
    expect(worker.disposeCalled, isFalse);
    expect(coordinator.snapshot.activeWorkers, 1);
    expect(lockManager.isLocked(session.id), isTrue);

    worker.allowCancel.complete();
    await disposeFuture;
    expect(worker.calls, ['start', 'cancel:start', 'cancel:end', 'stop', 'start', 'stop', 'dispose']);
    expect(lockManager.isLocked(session.id), isFalse);
  });

  test('logical-agent reservation matches provider and security profile', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_provider_profile_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessions = SessionService(baseDir: tempDir.path);
    final session = await sessions.createSession(type: SessionType.logicalAgent, provider: 'claude');
    final behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test');
    final primaryWorker = FakeWorkerService();
    final workspaceWorker = FakeWorkerService();
    final restrictedWorker = FakeWorkerService();
    final turns = turnManagerForRunners([
      TurnRunner(
        harness: primaryWorker,
        messages: messages,
        behavior: behavior,
        sessions: sessions,
        providerId: 'claude',
      ),
      TurnRunner(
        harness: workspaceWorker,
        messages: messages,
        behavior: behavior,
        sessions: sessions,
        providerId: 'claude',
        executionPolicy: const ExecutionPolicy.host(),
      ),
      TurnRunner(
        harness: restrictedWorker,
        messages: messages,
        behavior: behavior,
        sessions: sessions,
        providerId: 'claude',
        executionPolicy: const ExecutionPolicy.container('restricted'),
      ),
    ], sessions: sessions);
    addTearDown(turns.executions.dispose);

    final turnId = await turns.startTurn(session.id, const [], agentName: 'search');
    await workspaceWorker.turnInvoked;
    workspaceWorker.completeSuccess();
    await turns.waitForOutcome(session.id, turnId);

    final restrictedTurnId = await turns.reserveTurn(
      session.id,
      agentName: 'search',
      workerPolicy: const ExecutionPolicy.container('restricted'),
    );
    turns.executeTurn(session.id, restrictedTurnId, const [], agentName: 'search');
    await restrictedWorker.turnInvoked;
    restrictedWorker.completeSuccess();
    await turns.waitForOutcome(session.id, restrictedTurnId);

    expect(restrictedWorker.turnCalls, 1);
    expect(workspaceWorker.turnCalls, 1, reason: 'the unconstrained first turn may use the workspace worker');
    expect(primaryWorker.turnCalls, 0);
  });
}

final class _RecordingResetWorker extends FakeWorkerService {
  final List<String> resetSessionIds = [];

  @override
  Future<void> resetSessionContinuity(String sessionId) async {
    resetSessionIds.add(sessionId);
  }
}

final class _DelayedDisposeWorker extends FakeWorkerService {
  final disposeStarted = Completer<void>();
  final allowDispose = Completer<void>();
  var _crashed = false;

  @override
  WorkerState get state => _crashed ? WorkerState.crashed : WorkerState.idle;

  void completeCrashed() {
    _crashed = true;
    completeSuccess();
  }

  @override
  Future<void> dispose() async {
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await allowDispose.future;
    await super.dispose();
  }
}

final class _DelayedCancelRecoveryWorker extends FakeWorkerService {
  final cancelStarted = Completer<void>();
  final allowCancel = Completer<void>();
  final List<String> calls = [];
  var disposeCalled = false;

  @override
  Future<void> cancel() async {
    calls.add('cancel:start');
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await super.cancel();
    await allowCancel.future;
    calls.add('cancel:end');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    await super.stop();
  }

  @override
  Future<void> start() async {
    calls.add('start');
    await super.start();
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposeCalled = true;
    await super.dispose();
  }
}
