import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/src/harness_pool.dart' show HarnessPool;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:test/test.dart';

import 'turn_manager_test_support.dart';

void main() {
  test('concurrent first turns share one lazy runner until the final reservation releases', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_provider_session_test_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final messages = MessageService(baseDir: tempDir.path);
    final sessionService = SessionService(baseDir: tempDir.path);
    final session = await sessionService.createSession(provider: 'codex');
    final primaryWorker = FakeWorkerService();
    final codexWorker = FakeWorkerService();
    final behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test');
    final spawnGate = Completer<void>();
    final spawnStarted = Completer<void>();
    var spawnCalls = 0;
    late final HarnessPool pool;
    final coordinator = WorkerPoolCoordinator(
      pool: pool = HarnessPool(
        runners: [
          TurnRunner(
            harness: primaryWorker,
            messages: messages,
            behavior: behavior,
            sessions: sessionService,
            providerId: 'claude',
          ),
        ],
        maxConcurrentWorkers: 1,
      ),
      onSpawnNeeded: (provider) async {
        spawnCalls++;
        if (!spawnStarted.isCompleted) spawnStarted.complete();
        await spawnGate.future;
        pool.addRunner(
          TurnRunner(
            harness: codexWorker,
            messages: messages,
            behavior: behavior,
            sessions: sessionService,
            providerId: provider!,
          ),
        );
        return true;
      },
    );
    final providerTurns = TurnManager.fromPool(
      pool: pool,
      sessions: sessionService,
      workerPoolCoordinator: coordinator,
    );
    addTearDown(providerTurns.pool.dispose);

    final firstFuture = providerTurns.startTurn(session.id, []).then((turnId) => (index: 0, turnId: turnId));
    final secondFuture = providerTurns.startTurn(session.id, []).then((turnId) => (index: 1, turnId: turnId));
    await spawnStarted.future.timeout(const Duration(seconds: 1));
    expect(spawnCalls, 1);

    spawnGate.complete();
    final firstSettled = await Future.any([firstFuture, secondFuture]);
    final remainingFuture = firstSettled.index == 0 ? secondFuture : firstFuture;
    await codexWorker.turnInvoked;
    expect(pool.activeCount, 1);
    expect(pool.availableCount, 0);

    codexWorker.completeSuccess();
    await providerTurns.waitForOutcome(session.id, firstSettled.turnId);
    expect(pool.activeCount, 1, reason: 'the second reservation still owns the runner');

    final secondSettled = await remainingFuture;
    await codexWorker.turnInvoked;
    codexWorker.completeSuccess();
    await providerTurns.waitForOutcome(session.id, secondSettled.turnId);

    expect(pool.activeCount, 0);
    expect(pool.availableCount, 1);
    expect(codexWorker.turnCalls, 2);
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
    final pool = HarnessPool(runners: [primaryRunner, taskRunner], maxConcurrentWorkers: 1);
    final turns = TurnManager.fromPool(pool: pool, sessions: sessions);
    addTearDown(pool.dispose);

    final parentTurnId = await primaryRunner.reserveTurn(parentSession.id);

    await turns.resetProviderSessionContinuity(logicalAgentSession.id);

    expect(primaryWorker.resetSessionIds, isEmpty);
    expect(taskWorker.resetSessionIds, [logicalAgentSession.id]);
    final releasedOutcome = expectLater(primaryRunner.waitForOutcome(parentSession.id, parentTurnId), throwsStateError);
    primaryRunner.releaseTurn(parentSession.id, parentTurnId);
    await releasedOutcome;
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
    final pool = HarnessPool(
      runners: [
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
          profileId: 'workspace',
        ),
        TurnRunner(
          harness: restrictedWorker,
          messages: messages,
          behavior: behavior,
          sessions: sessions,
          providerId: 'claude',
          profileId: 'restricted',
        ),
      ],
      maxConcurrentWorkers: 2,
    );
    final turns = TurnManager.fromPool(pool: pool, sessions: sessions);
    addTearDown(pool.dispose);

    final turnId = await turns.startTurn(session.id, const [], agentName: 'search');
    await workspaceWorker.turnInvoked;
    workspaceWorker.completeSuccess();
    await turns.waitForOutcome(session.id, turnId);

    final restrictedTurnId = await turns.reserveTurn(session.id, agentName: 'search', workerProfile: 'restricted');
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
