import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnRunner;
import 'package:dartclaw_server/src/concurrency/session_lock_manager.dart' show SessionLockTimerFactory;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_server/src/turn_wait_status.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:fake_async/fake_async.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

TurnRunner _buildRunner({
  required AgentHarness harness,
  required MessageService messages,
  required String workspaceDir,
  required SessionService sessions,
  required TurnStateStore turnState,
  required KvService kvService,
  SessionResetService? resetService,
  String providerId = 'claude',
  Duration stallTimeout = Duration.zero,
  TurnProgressAction stallAction = TurnProgressAction.warn,
  TurnMonitorConfig turnMonitor = const TurnMonitorConfig.defaults(),
  EventBus? eventBus,
  SelfImprovementService? selfImprovement,
  GuardChain? guardChain,
  TaskToolFilterGuard? taskToolFilterGuard,
  SessionLockTimerFactory? turnMonitorTimerFactory,
  DateTime Function()? turnMonitorNow,
}) {
  return TurnRunner(
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    sessions: sessions,
    turnState: turnState,
    kv: kvService,
    resetService: resetService,
    providerId: providerId,
    stallTimeout: stallTimeout,
    stallAction: stallAction,
    turnMonitor: turnMonitor,
    eventBus: eventBus,
    selfImprovement: selfImprovement,
    guardChain: guardChain,
    taskToolFilterGuard: taskToolFilterGuard,
    turnMonitorTimerFactory: turnMonitorTimerFactory,
    turnMonitorNow: turnMonitorNow,
  );
}

class _TurnMonitorFakeTime {
  static final _initialTime = DateTime(2026);
  final _async = FakeAsync(initialTime: _initialTime);

  DateTime now() => _async.getClock(_initialTime).now();

  Timer create(Duration duration, void Function() callback) => _async.run((_) => Timer(duration, callback));

  Future<void> elapseAsync(Duration duration) async {
    await pumpEventQueue();
    _async.elapse(duration);
    await pumpEventQueue();
  }
}

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeAgentHarness worker;
  late TurnRunner runner;
  late Database turnStateDb;
  late TurnStateStore turnState;
  late KvService kvService;
  late _TurnMonitorFakeTime turnMonitorTime;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_runner_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FakeAgentHarness();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    turnMonitorTime = _TurnMonitorFakeTime();
    runner = _buildRunner(
      harness: worker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TurnRunner monitoredRunner(AgentHarness harness, {EventBus? eventBus, SelfImprovementService? selfImprovement}) {
    return _buildRunner(
      harness: harness,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      turnMonitor: const TurnMonitorConfig(
        waitWarningAfter: Duration(milliseconds: 10),
        stuckAfter: Duration(milliseconds: 25),
      ),
      turnMonitorTimerFactory: turnMonitorTime.create,
      turnMonitorNow: turnMonitorTime.now,
      eventBus: eventBus,
      selfImprovement: selfImprovement,
    );
  }

  test('reserves turn and returns turnId', () async {
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.reserveTurn(session.id);

    expect(turnId, isNotEmpty);
    expect(runner.isActive(session.id), isTrue);
    expect(runner.activeTurnId(session.id), turnId);
    expect(runner.activeSessionIds, contains(session.id));

    // Execute the turn to complete it properly (releaseTurn fires an error on
    // the outcome completer which propagates as an unhandled async error).
    scheduleTurnCompletion(worker, responseText: 'ok');
    runner.executeTurn(session.id, turnId, [
      {'role': 'user', 'content': 'test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);
  });

  test('executes turn and produces TurnOutcome.completed', () async {
    scheduleTurnCompletion(worker, responseText: 'Hello from runner!');
    final session = await sessions.getOrCreateMainSession();
    await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Hi');

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Hi'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.responseText, 'Hello from runner!');
    expect(runner.isActive(session.id), isFalse);
  });

  test('per-turn toolless policy is applied session-scoped during the turn and cleared after (TD-109)', () async {
    // Regression guard for TD-109: the untrusted knowledge-inbox extraction turn
    // dispatches with allowedTools:['__knowledge_inbox_no_tools__'] + readOnly.
    // TurnRunner must apply that per-turn policy to the session BEFORE the harness
    // runs and clear it after, so a prompt-injected source cannot induce tool use
    // — without the enforcement leaking onto concurrent turns on other sessions.
    final guard = TaskToolFilterGuard();
    final guardedRunner = _buildRunner(
      harness: worker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      taskToolFilterGuard: guard,
    );
    final session = await sessions.getOrCreateMainSession();

    Future<GuardVerdict> probeFetch(String sessionId) => guard.evaluate(
      GuardContext(hookPoint: 'beforeToolCall', toolName: 'web_fetch', sessionId: sessionId, timestamp: DateTime.now()),
    );

    GuardVerdict? midTurnScoped;
    GuardVerdict? midTurnConcurrent;
    unawaited(() async {
      await worker.turnInvoked;
      // Harness dispatched → the per-turn policy is now applied to this session.
      midTurnScoped = await probeFetch(session.id);
      midTurnConcurrent = await probeFetch('other-interactive-session');
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await guardedRunner.startTurn(
      session.id,
      [
        {'role': 'user', 'content': 'untrusted inbox source'},
      ],
      allowedTools: const ['__knowledge_inbox_no_tools__'],
      readOnly: true,
    );
    await guardedRunner.waitForOutcome(session.id, turnId);

    // web_fetch is read-only-safe, so a mid-turn block proves the toolless
    // allowlist (not read-only) was applied to the extraction session.
    expect(midTurnScoped?.isBlock, isTrue);
    // The restriction is session-scoped: a concurrent turn on another session is
    // unaffected (the leak TD-109 warned about).
    expect(midTurnConcurrent?.isPass, isTrue);
    // Policy cleared after the turn — the extraction session is unrestricted again.
    expect((await probeFetch(session.id)).isPass, isTrue);
  });

  test('handles agent failure and produces TurnOutcome.failed', () async {
    scheduleTurnCompletion(worker, error: StateError('simulated crash'));
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Will fail'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.failed);
    expect(runner.isActive(session.id), isFalse);
  });

  for (final providerResult in [
    (
      name: 'Claude',
      result: {
        'stop_reason': 'error',
        'error': 'Failed to authenticate. API Error: 401 Invalid authentication credentials',
        'input_tokens': 0,
        'output_tokens': 0,
      },
    ),
    (
      name: 'Codex',
      result: {'stop_reason': 'error', 'error': 'usageLimitExceeded', 'input_tokens': 3, 'output_tokens': 1},
    ),
  ]) {
    test('${providerResult.name} terminal provider error fails the turn without persisting partial output', () async {
      scheduleTurnCompletion(worker, responseText: 'partial provider output', result: providerResult.result);
      final session = await sessions.getOrCreateMainSession();

      final turnId = await runner.startTurn(session.id, [
        {'role': 'user', 'content': 'Will fail at the provider'},
      ]);
      final outcome = await runner.waitForOutcome(session.id, turnId);
      final storedAssistant = (await messages.getMessages(session.id)).where((message) => message.role == 'assistant');

      expect(outcome.status, TurnStatus.failed);
      expect(outcome.errorMessage, providerResult.result['error']);
      expect(storedAssistant.single.content, providerResult.result['error']);
      expect(storedAssistant.single.content, isNot(contains('partial provider output')));
    });
  }

  test('emits turn wait-state events for running and natural completion', () async {
    final bus = EventBus();
    final events = <TurnWaitStateChangedEvent>[];
    final sub = bus.on<TurnWaitStateChangedEvent>().listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      await bus.dispose();
    });
    runner = _buildRunner(
      harness: worker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      eventBus: bus,
    );
    scheduleTurnCompletion(worker, responseText: 'done');
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'complete naturally'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);
    await pumpEventQueue();

    expect(outcome.status, TurnStatus.completed);
    expect(events.map((event) => event.state), containsAllInOrder([TurnWaitState.running, TurnWaitState.completed]));
    expect(events.last.turnId, turnId);
    expect(events.last.waitReason, TurnWaitReason.unknown);
  });

  test('emits turn wait-state failed event for natural failure', () async {
    final bus = EventBus();
    final events = <TurnWaitStateChangedEvent>[];
    final sub = bus.on<TurnWaitStateChangedEvent>().listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      await bus.dispose();
    });
    runner = _buildRunner(
      harness: worker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      eventBus: bus,
    );
    scheduleTurnCompletion(worker, error: StateError('simulated crash'));
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'fail naturally'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);
    await pumpEventQueue();

    expect(outcome.status, TurnStatus.failed);
    expect(events.map((event) => event.state), containsAllInOrder([TurnWaitState.running, TurnWaitState.failed]));
    expect(events.last.turnId, turnId);
    expect(events.last.canCancel, isFalse);
  });

  test('cancels active turn', () async {
    runner = monitoredRunner(worker);
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Cancel me'},
    ]);

    await worker.turnInvoked;
    await runner.cancelTurn(session.id);

    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.cancelled);
  });

  test('waitForOutcome returns completed outcome', () async {
    scheduleTurnCompletion(worker, responseText: 'Done');
    final session = await sessions.getOrCreateMainSession();

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Test'},
    ]);

    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.completed);
    expect(outcome.sessionId, session.id);
    expect(outcome.turnId, turnId);
  });

  test('harness getter returns the underlying harness', () {
    expect(runner.harness, same(worker));
  });

  test('releaseTurn removes persisted turn state and fails the pending outcome', () async {
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.reserveTurn(session.id);

    expect((await turnState.getAll())[session.id]?.turnId, equals(turnId));

    final outcomeExpectation = runner
        .waitForOutcome(session.id, turnId)
        .then<void>(
          (_) => fail('Expected released turn to fail the pending outcome'),
          onError: (Object error, StackTrace _) {
            expect(
              error,
              isA<StateError>().having(
                (stateError) => stateError.message,
                'message',
                contains('released without execution'),
              ),
            );
          },
        );
    runner.releaseTurn(session.id, turnId);
    await pumpEventQueue();

    expect(runner.isActive(session.id), isFalse);
    expect(await turnState.getAll(), isNot(contains(session.id)));
    await outcomeExpectation;
  });

  test('turnStatus reports waiting and stuck for queued same-session lock wait', () async {
    final bus = EventBus();
    final events = <TurnWaitStateChangedEvent>[];
    final sub = bus.on<TurnWaitStateChangedEvent>().listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      await bus.dispose();
    });
    runner = monitoredRunner(worker, eventBus: bus);
    final session = await sessions.getOrCreateMainSession();
    final firstTurnId = await runner.reserveTurn(session.id, taskId: 'task-wait');
    final firstOutcome = runner.waitForOutcome(session.id, firstTurnId).catchError((_) {
      return TurnOutcome(
        turnId: firstTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    final queuedReserve = runner.reserveTurn(session.id);

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    expect(runner.turnStatus(session.id).state, TurnWaitState.waiting);
    expect(runner.turnStatus(session.id).waitReason, TurnWaitReason.sessionLock);
    expect(runner.turnStatus(session.id).taskId, 'task-wait');

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 20));
    final stuck = runner.turnStatus(session.id);
    expect(stuck.state, TurnWaitState.stuck);
    expect(stuck.taskId, 'task-wait');
    expect(stuck.canCancel, isTrue);
    expect(events.map((event) => event.state), containsAllInOrder([TurnWaitState.waiting, TurnWaitState.stuck]));
    expect(events.map((event) => event.taskId), contains('task-wait'));

    runner.releaseTurn(session.id, firstTurnId);
    await firstOutcome;
    final secondTurnId = await queuedReserve.timeout(const Duration(seconds: 1));
    final secondOutcome = runner.waitForOutcome(session.id, secondTurnId).catchError((_) {
      return TurnOutcome(
        turnId: secondTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    runner.releaseTurn(session.id, secondTurnId);
    await secondOutcome;
  });

  test('S07/TI10 reports provider_turn from provider progress before global timeout', () async {
    final bus = EventBus();
    final events = <TurnWaitStateChangedEvent>[];
    final sub = bus.on<TurnWaitStateChangedEvent>().listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      await bus.dispose();
    });
    runner = monitoredRunner(worker, eventBus: bus);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Provider wait'},
    ]);
    await worker.turnInvoked;
    worker.emit(ProviderProgressBridgeEvent(kind: 'provider_turn', text: 'model is still processing'));

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    final waiting = runner.turnStatus(session.id);
    expect(waiting.state, TurnWaitState.waiting);
    expect(waiting.waitReason, TurnWaitReason.providerTurn);
    expect(waiting.canCancel, isTrue);

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 20));
    final stuck = runner.turnStatus(session.id);
    expect(stuck.state, TurnWaitState.stuck);
    expect(stuck.waitReason, TurnWaitReason.providerTurn);
    expect(stuck.canCancel, isTrue);
    expect(
      events.where((event) => event.waitReason == TurnWaitReason.providerTurn).map((event) => event.state),
      containsAllInOrder([TurnWaitState.waiting, TurnWaitState.stuck]),
    );

    await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await runner.waitForOutcome(session.id, turnId);
  });

  test('S07/TI10 reports tool_approval as cancellable only after stale threshold', () async {
    runner = monitoredRunner(worker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Approval wait'},
    ]);
    await worker.turnInvoked;
    worker.emit(ToolApprovalWaitEvent(requestId: 'approval-1', toolName: 'shell'));

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    final waiting = runner.turnStatus(session.id);
    expect(waiting.state, TurnWaitState.waiting);
    expect(waiting.waitReason, TurnWaitReason.toolApproval);
    expect(waiting.canCancel, isFalse);
    await expectLater(
      runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel),
      throwsA(isA<TurnCancelException>().having((error) => error.code, 'code', 'TURN_NOT_CANCELLABLE')),
    );
    expect(runner.activeTurnId(session.id), turnId);

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 20));
    final stuck = runner.turnStatus(session.id);
    expect(stuck.state, TurnWaitState.stuck);
    expect(stuck.waitReason, TurnWaitReason.toolApproval);
    expect(stuck.canCancel, isTrue);

    await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await runner.waitForOutcome(session.id, turnId);
  });

  test('S07/TI10 keeps non-stale tool_approval non-cancellable while session lock wait is visible', () async {
    runner = monitoredRunner(worker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Approval plus queued wait'},
    ]);
    await worker.turnInvoked;
    worker.emit(ToolApprovalWaitEvent(requestId: 'approval-lock-wait', toolName: 'shell'));

    final queuedReserve = runner.reserveTurn(session.id);
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    final waiting = runner.turnStatus(session.id);
    expect(waiting.state, TurnWaitState.waiting);
    expect(waiting.waitReason, TurnWaitReason.sessionLock);
    expect(waiting.canCancel, isFalse);
    await expectLater(
      runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel),
      throwsA(isA<TurnCancelException>().having((error) => error.code, 'code', 'TURN_NOT_CANCELLABLE')),
    );
    expect(runner.activeTurnId(session.id), turnId);

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 20));
    final stuck = runner.turnStatus(session.id);
    expect(stuck.state, TurnWaitState.stuck);
    expect(stuck.waitReason, TurnWaitReason.sessionLock);
    expect(stuck.canCancel, isTrue);

    await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await runner.waitForOutcome(session.id, turnId);
    final queuedTurnId = await queuedReserve.timeout(const Duration(seconds: 1));
    final queuedOutcome = runner.waitForOutcome(session.id, queuedTurnId).catchError((_) {
      return TurnOutcome(
        turnId: queuedTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    runner.releaseTurn(session.id, queuedTurnId);
    await queuedOutcome;
  });

  test('S07/TI10 clears tool_approval when approval is answered', () async {
    runner = monitoredRunner(worker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Approval resolves'},
    ]);
    await worker.turnInvoked;
    worker.emit(ToolApprovalWaitEvent(requestId: 'approval-2', toolName: 'shell'));

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    expect(runner.turnStatus(session.id).waitReason, TurnWaitReason.toolApproval);
    expect(runner.turnStatus(session.id).canCancel, isFalse);

    worker.emit(ToolApprovalResolvedEvent(requestId: 'approval-2'));
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    final waiting = runner.turnStatus(session.id);
    expect(waiting.state, TurnWaitState.waiting);
    expect(waiting.waitReason, TurnWaitReason.unknown);
    expect(waiting.canCancel, isTrue);

    await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await runner.waitForOutcome(session.id, turnId);
  });

  test('S07/TI10 reports unknown for unclassified active-turn stall', () async {
    runner = monitoredRunner(worker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Unknown wait'},
    ]);
    await worker.turnInvoked;
    await expectLater(
      runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel),
      throwsA(isA<TurnCancelException>().having((error) => error.code, 'code', 'TURN_NOT_CANCELLABLE')),
    );
    expect(runner.activeTurnId(session.id), turnId);

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    final waiting = runner.turnStatus(session.id);
    expect(waiting.state, TurnWaitState.waiting);
    expect(waiting.waitReason, TurnWaitReason.unknown);
    expect(waiting.canCancel, isTrue);

    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 20));
    final stuck = runner.turnStatus(session.id);
    expect(stuck.state, TurnWaitState.stuck);
    expect(stuck.waitReason, TurnWaitReason.unknown);
    expect(stuck.canCancel, isTrue);

    await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await runner.waitForOutcome(session.id, turnId);
  });

  test('accepted cancel wins over provider completion race and emits terminal cancelled state', () async {
    final bus = EventBus();
    final events = <TurnWaitStateChangedEvent>[];
    final sub = bus.on<TurnWaitStateChangedEvent>().listen(events.add);
    final raceWorker = DelayedCancelHarness();
    addTearDown(() async {
      await sub.cancel();
      await bus.dispose();
      await raceWorker.dispose();
    });
    runner = monitoredRunner(raceWorker, eventBus: bus);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Race cancel'},
    ]);
    final outcomeFuture = runner.waitForOutcome(session.id, turnId);
    await raceWorker.turnInvoked;
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));
    expect(runner.turnStatus(session.id).state, TurnWaitState.waiting);

    final cancelFuture = runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await raceWorker.cancelStarted.future;
    var nextReserveCompleted = false;
    final nextReserve = runner.reserveTurn(session.id);
    unawaited(nextReserve.then((_) => nextReserveCompleted = true));
    await pumpEventQueue();
    expect(nextReserveCompleted, isTrue);

    raceWorker.emit(DeltaEvent('late completion'));
    raceWorker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    raceWorker.allowCancelReturn.complete();

    final cancelResult = await cancelFuture.timeout(const Duration(seconds: 1));
    final nextTurnId = await nextReserve.timeout(const Duration(seconds: 1));
    final nextOutcome = runner.waitForOutcome(session.id, nextTurnId).catchError((_) {
      return TurnOutcome(
        turnId: nextTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    final outcome = await outcomeFuture;
    final storedMessages = await messages.getMessages(session.id);
    var thirdReserveCompleted = false;
    final thirdReserve = runner.reserveTurn(session.id);
    unawaited(thirdReserve.then((_) => thirdReserveCompleted = true));
    await pumpEventQueue();

    expect(cancelResult.status, TurnWaitState.cancelled);
    expect(cancelResult.releasedSessionLock, isTrue);
    expect(raceWorker.stopCalled, isTrue);
    expect(raceWorker.startCalled, isTrue);
    expect(outcome.status, TurnStatus.cancelled);
    expect(runner.activeTurnId(session.id), nextTurnId);
    expect(thirdReserveCompleted, isFalse);
    expect(storedMessages.where((message) => message.role == 'assistant'), isEmpty);
    expect(events.map((event) => event.state), containsAllInOrder([TurnWaitState.cancelling, TurnWaitState.cancelled]));

    runner.releaseTurn(session.id, nextTurnId);
    await nextOutcome;
    final thirdTurnId = await thirdReserve.timeout(const Duration(seconds: 1));
    final thirdOutcome = runner.waitForOutcome(session.id, thirdTurnId).catchError((_) {
      return TurnOutcome(
        turnId: thirdTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    runner.releaseTurn(session.id, thirdTurnId);
    await thirdOutcome;
  });

  test('accepted cancel cleanup failure force-completes and releases the session', () async {
    final failingWorker = FailingCancelCleanupHarness();
    final selfImprovement = SelfImprovementService(workspaceDir: workspaceDir);
    addTearDown(failingWorker.dispose);
    addTearDown(selfImprovement.dispose);
    runner = monitoredRunner(failingWorker, selfImprovement: selfImprovement);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Cleanup fails'},
    ]);
    await failingWorker.turnInvoked;
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));

    final result = await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await pumpEventQueue();

    expect(result.status, TurnWaitState.cancelled);
    expect(result.releasedSessionLock, isTrue);
    expect(failingWorker.cancelCalled, isTrue);
    expect(failingWorker.stopCalled, isTrue);
    expect(failingWorker.stopCalls, 1);
    expect(runner.activeTurnId(session.id), isNull);
    expect((await runner.waitForOutcome(session.id, turnId)).status, TurnStatus.cancelled);
    expect(await messages.getMessages(session.id), isEmpty);
    expect(await selfImprovement.readErrors(), isEmpty);

    final nextReserve = runner.reserveTurn(session.id);
    final nextTurnId = await nextReserve.timeout(const Duration(seconds: 1));
    final nextOutcome = runner.waitForOutcome(session.id, nextTurnId).catchError((_) {
      return TurnOutcome(
        turnId: nextTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    runner.releaseTurn(session.id, nextTurnId);
    await nextOutcome;
  });

  test('accepted cancel via worker throw does not leak the externally-completed turn id', () async {
    // Default FakeAgentHarness.cancel() force-fails the in-flight turn() — the
    // dominant SIGTERM-killed case — so executeTurn exits through catch + finally
    // rather than the normal-return remove. Asserts the finally cleanup runs.
    final leakWorker = FakeAgentHarness();
    addTearDown(leakWorker.dispose);
    runner = monitoredRunner(leakWorker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Leak check'},
    ]);
    await leakWorker.turnInvoked;
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));

    final result = await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await pumpEventQueue();

    expect(result.status, TurnWaitState.cancelled);
    expect((await runner.waitForOutcome(session.id, turnId)).status, TurnStatus.cancelled);
    expect(
      runner.tracksExternalCompletion(turnId),
      isFalse,
      reason: '_externallyCompletedTurns must be cleaned on the accepted-cancel-via-throw path',
    );
  });

  test('accepted cancel releases the session before worker cleanup finishes', () async {
    final hangingWorker = HangingCancelHarness();
    addTearDown(hangingWorker.dispose);
    runner = monitoredRunner(hangingWorker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Cleanup hangs'},
    ]);
    await hangingWorker.turnInvoked;
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));

    final result = await runner
        .cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel)
        .timeout(const Duration(seconds: 1));
    await hangingWorker.cancelStarted.future.timeout(const Duration(seconds: 1));

    expect(result.status, TurnWaitState.cancelled);
    expect(result.releasedSessionLock, isTrue);
    expect(runner.activeTurnId(session.id), isNull);
    expect((await runner.waitForOutcome(session.id, turnId)).status, TurnStatus.cancelled);

    final nextTurnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 1));
    final nextOutcome = runner.waitForOutcome(session.id, nextTurnId).catchError((_) {
      return TurnOutcome(
        turnId: nextTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    runner.releaseTurn(session.id, nextTurnId);
    await nextOutcome;
  });

  test('next execution waits for accepted cancel recovery before calling worker', () async {
    final hangingWorker = HangingCancelHarness();
    addTearDown(hangingWorker.dispose);
    runner = monitoredRunner(hangingWorker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Cleanup hangs'},
    ]);
    await hangingWorker.turnInvoked;
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));

    await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await hangingWorker.cancelStarted.future.timeout(const Duration(seconds: 1));

    final nextTurnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Next turn'},
    ]);
    await pumpEventQueue(times: 5);

    expect(hangingWorker.turnCallCount, 1);

    hangingWorker.cancelCompleter.complete();
    await pumpEventQueue();
    expect(hangingWorker.turnCallCount, 2);

    hangingWorker.completeSuccess(turnResult());
    expect((await runner.waitForOutcome(session.id, nextTurnId)).status, TurnStatus.completed);
  });

  test('accepted cancel releases the session when restart fails after a pending provider cancel', () async {
    final failingWorker = FailingStartAfterCancelHarness();
    addTearDown(failingWorker.dispose);
    runner = monitoredRunner(failingWorker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Restart fails'},
    ]);
    await failingWorker.turnInvoked;
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));

    final result = await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    await pumpEventQueue();

    expect(result.status, TurnWaitState.cancelled);
    expect(result.releasedSessionLock, isTrue);
    expect(failingWorker.cancelCalled, isTrue);
    expect(failingWorker.stopCalled, isTrue);
    expect(failingWorker.startCalled, isTrue);
    expect(runner.activeTurnId(session.id), isNull);
    expect((await runner.waitForOutcome(session.id, turnId)).status, TurnStatus.cancelled);

    final nextTurnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 1));
    final nextOutcome = runner.waitForOutcome(session.id, nextTurnId).catchError((_) {
      return TurnOutcome(
        turnId: nextTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    runner.releaseTurn(session.id, nextTurnId);
    await nextOutcome;
  });

  test('restart failure after accepted cancel fails the next execution explicitly', () async {
    final failingWorker = FailingStartAfterCancelHarness();
    addTearDown(failingWorker.dispose);
    runner = monitoredRunner(failingWorker);
    final session = await sessions.getOrCreateMainSession();
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Restart fails'},
    ]);
    await failingWorker.turnInvoked;
    await turnMonitorTime.elapseAsync(const Duration(milliseconds: 15));

    await runner.cancelTurnById(session.id, turnId, TurnCancelReason.operatorCancel);
    final nextTurnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Next turn'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, nextTurnId);

    expect(outcome.status, TurnStatus.failed);
    expect(failingWorker.turnCallCount, 1);
  });

  test('persists and cleans turn state via store', () async {
    final session = await sessions.getOrCreateMainSession();
    final releaseCompletion = Completer<void>();
    scheduleTurnCompletion(worker, responseText: 'Tracked', waitUntil: releaseCompletion.future);

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Track turn state'},
    ]);

    final activeState = (await turnState.getAll())[session.id];
    expect(activeState, isNotNull);
    expect(activeState?.turnId, equals(turnId));
    expect(activeState?.startedAt, isA<DateTime>());

    releaseCompletion.complete();
    final outcome = await runner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.completed);
    expect(await turnState.getAll(), isNot(contains(session.id)));
  });

  test('persists usage even when the harness does not report USD cost', () async {
    final costWorker = FakeAgentHarness(supportsCostReporting: false);
    addTearDown(() async => costWorker.dispose());
    final costRunner = _buildRunner(
      harness: costWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMainSession();
    scheduleTurnCompletion(
      costWorker,
      responseText: 'No cost',
      result: turnResult(inputTokens: 2, outputTokens: 3, totalCostUsd: 9.99),
    );

    final turnId = await costRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Skip cost'},
    ]);

    final outcome = await costRunner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    final usageData = await readSessionCost(kvService, session.id);
    expect(usageData.keys.toSet(), {
      'input_tokens',
      'output_tokens',
      'cache_read_tokens',
      'cache_write_tokens',
      'total_tokens',
      'effective_tokens',
      'estimated_cost_usd',
      'turn_count',
      'provider',
    });
    expect(usageData.containsKey('new_input_tokens'), isFalse);
    expect(usageData['provider'], 'claude');
    expect(usageData['input_tokens'], 2);
    expect(usageData['output_tokens'], 3);
    expect(usageData['total_tokens'], 5);
    expect(usageData['cache_read_tokens'], 0);
    expect(usageData['effective_tokens'], 5);
    expect((usageData['estimated_cost_usd'] as num).toDouble(), 0.0);
    expect(usageData['turn_count'], 1);
  });

  test('turn outcome carries cacheReadTokens when available', () async {
    final cachedWorker = FakeAgentHarness(supportsCachedTokens: true);
    addTearDown(() async => cachedWorker.dispose());
    final cachedRunner = _buildRunner(
      harness: cachedWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMainSession();
    scheduleTurnCompletion(
      cachedWorker,
      responseText: 'Cached',
      result: turnResult(inputTokens: 1, outputTokens: 1, cachedInputTokens: 7),
    );

    final turnId = await cachedRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Return cached tokens'},
    ]);

    final outcome = await cachedRunner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.cacheReadTokens, 7);
    // 1 + 1 + (0 * 125 ~/ 100 = 0) + (7 * 10 ~/ 100 = 0) = 2.
    expect(outcome.effectiveTokens, 2);
  });

  test('startTurn forwards maxTurns to the harness', () async {
    final boundedWorker = FakeAgentHarness();
    addTearDown(() async => boundedWorker.dispose());
    final boundedRunner = _buildRunner(
      harness: boundedWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMainSession();
    scheduleTurnCompletion(boundedWorker, responseText: 'bounded');

    final turnId = await boundedRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Bound this turn'},
    ], maxTurns: 1);

    final outcome = await boundedRunner.waitForOutcome(session.id, turnId);
    expect(outcome.status, TurnStatus.completed);
    expect(boundedWorker.lastMaxTurns, 1);
  });

  test('persists provider and accumulates cached input tokens across turns', () async {
    final codexWorker = FakeAgentHarness(supportsCostReporting: false, supportsCachedTokens: true);
    addTearDown(() async => codexWorker.dispose());
    final codexRunner = _buildRunner(
      harness: codexWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      providerId: 'codex',
    );
    final session = await sessions.getOrCreateMainSession();

    scheduleTurnCompletion(codexWorker, result: turnResult(inputTokens: 2, outputTokens: 1, cachedInputTokens: 5));
    final firstTurnId = await codexRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'first'},
    ]);
    await codexRunner.waitForOutcome(session.id, firstTurnId);

    scheduleTurnCompletion(codexWorker, result: turnResult(inputTokens: 3, outputTokens: 4, cachedInputTokens: 7));
    final secondTurnId = await codexRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'second'},
    ]);
    await codexRunner.waitForOutcome(session.id, secondTurnId);

    final costData = await readSessionCost(kvService, session.id);
    expect(costData.keys.toSet(), {
      'input_tokens',
      'output_tokens',
      'cache_read_tokens',
      'cache_write_tokens',
      'total_tokens',
      'effective_tokens',
      'estimated_cost_usd',
      'turn_count',
      'provider',
    });
    expect(costData.containsKey('new_input_tokens'), isFalse);
    expect(costData['provider'], 'codex');
    expect(costData['input_tokens'], 5);
    expect(costData['output_tokens'], 5);
    expect(costData['total_tokens'], 10);
    expect(costData['cache_read_tokens'], 12);
    // Turn 1: 2+1+(5*0.1~/1=0) = 3. Turn 2: 3+4+(7*0.1~/1=0) = 7. Accumulated = 10.
    expect(costData['effective_tokens'], 10);
    expect((costData['estimated_cost_usd'] as num).toDouble(), 0.0);
    expect(costData['turn_count'], 2);
  });

  test('effective_tokens accumulates weighted cache-write and cache-read through _trackSessionUsage', () async {
    final cachedWorker = FakeAgentHarness(supportsCachedTokens: true);
    addTearDown(() async => cachedWorker.dispose());
    final cachedRunner = _buildRunner(
      harness: cachedWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
    );
    final session = await sessions.getOrCreateMainSession();
    // Values chosen so both weights produce non-zero integer contributions.
    scheduleTurnCompletion(
      cachedWorker,
      result: turnResult(inputTokens: 100, outputTokens: 50, cachedInputTokens: 1000, cacheWriteTokens: 200),
    );
    final turnId = await cachedRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'Exercise both cache weights'},
    ]);
    await cachedRunner.waitForOutcome(session.id, turnId);

    final costData = await readSessionCost(kvService, session.id);
    // 100 + 50 + (200 * 125 ~/ 100 = 250) + (1000 * 10 ~/ 100 = 100) = 500
    expect(costData['effective_tokens'], 500);
    expect(costData['cache_read_tokens'], 1000);
    expect(costData['cache_write_tokens'], 200);
  });

  test('preserves the first provider written for a session cost record', () async {
    final codexWorker = FakeAgentHarness(supportsCostReporting: false, supportsCachedTokens: true);
    final claudeWorker = FakeAgentHarness();
    addTearDown(() async => codexWorker.dispose());
    addTearDown(() async => claudeWorker.dispose());
    final codexRunner = _buildRunner(
      harness: codexWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      providerId: 'codex',
    );
    final claudeRunner = _buildRunner(
      harness: claudeWorker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      providerId: 'claude',
    );
    final session = await sessions.getOrCreateMainSession();

    scheduleTurnCompletion(
      codexWorker,
      result: turnResult(inputTokens: 1, outputTokens: 1, totalCostUsd: 0.10, cachedInputTokens: 3),
    );
    final codexTurnId = await codexRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'codex'},
    ]);
    await codexRunner.waitForOutcome(session.id, codexTurnId);

    scheduleTurnCompletion(claudeWorker, result: turnResult(inputTokens: 2, outputTokens: 2, totalCostUsd: 0.20));
    final claudeTurnId = await claudeRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'claude'},
    ]);
    await claudeRunner.waitForOutcome(session.id, claudeTurnId);

    final costData = await readSessionCost(kvService, session.id);
    expect(costData['provider'], 'codex');
    expect(costData['cache_read_tokens'], 3);
    expect(costData['turn_count'], 2);
  });

  test('defaults session cost provider to claude and treats missing cache_read_tokens as zero', () async {
    final session = await sessions.getOrCreateMainSession();

    scheduleTurnCompletion(worker, result: turnResult(inputTokens: 4, outputTokens: 6, totalCostUsd: 0.50));
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'default provider'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    final costData = await readSessionCost(kvService, session.id);
    expect(costData['provider'], 'claude');
    expect(costData['cache_read_tokens'], 0);
  });

  test('tool call correlation produces ToolCallRecord with correct fields', () async {
    final session = await sessions.getOrCreateMainSession();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_1', input: {'command': 'ls'}));
      await pumpEventQueue();
      worker.emit(ToolResultEvent(toolId: 'tu_1', output: 'file.txt', isError: false));
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'run tool'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.toolCalls, hasLength(1));
    expect(outcome.toolCalls[0].name, 'bash');
    expect(outcome.toolCalls[0].success, isTrue);
    expect(outcome.toolCalls[0].errorType, isNull);
    expect(outcome.toolCalls[0].durationMs, greaterThanOrEqualTo(0));
  });

  test('incomplete tool call produces ToolCallRecord with success: false and errorType: incomplete', () async {
    final session = await sessions.getOrCreateMainSession();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_orphan', input: {'command': 'sleep 999'}));
      // No ToolResultEvent — turn completes before tool returns.
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'incomplete tool'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.toolCalls, hasLength(1));
    final record = outcome.toolCalls[0];
    expect(record.name, 'bash');
    expect(record.success, isFalse);
    expect(record.errorType, 'incomplete');
  });

  test('turnDuration is set on TurnOutcome', () async {
    final session = await sessions.getOrCreateMainSession();

    scheduleTurnCompletion(worker, responseText: 'done');

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'duration test'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.turnDuration.inMilliseconds, greaterThanOrEqualTo(0));
  });

  test('progress events reset session activity throughout a running turn', () async {
    final resetService = RecordingSessionResetService(sessions: sessions, messages: messages);
    final resetAwareRunner = _buildRunner(
      harness: worker,
      messages: messages,
      workspaceDir: workspaceDir,
      sessions: sessions,
      turnState: turnState,
      kvService: kvService,
      resetService: resetService,
    );
    final session = await sessions.getOrCreateMainSession();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(DeltaEvent('thinking'));
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tool-1', input: {'command': 'ls'}));
      worker.emit(ToolResultEvent(toolId: 'tool-1', output: 'ok', isError: false));
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await resetAwareRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'keep the idle timer alive'},
    ]);
    final outcome = await resetAwareRunner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(
      resetService.touchedSessions,
      [session.id, session.id, session.id, session.id],
      reason: 'reserveTurn should touch once and every progress event should refresh activity',
    );
  });

  test('failed tool call produces ToolCallRecord with success: false and errorType: tool_error', () async {
    final session = await sessions.getOrCreateMainSession();

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_err', input: {'command': 'bad'}));
      await pumpEventQueue();
      worker.emit(ToolResultEvent(toolId: 'tu_err', output: 'permission denied', isError: true));
      await pumpEventQueue();
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'error tool'},
    ]);
    final outcome = await runner.waitForOutcome(session.id, turnId);

    expect(outcome.status, TurnStatus.completed);
    expect(outcome.toolCalls, hasLength(1));
    final record = outcome.toolCalls[0];
    expect(record.name, 'bash');
    expect(record.success, isFalse);
    expect(record.errorType, 'tool_error');
  });

  test('progressEvents emits TextDelta, ToolStarted, ToolCompleted in correct order', () async {
    final session = await sessions.getOrCreateMainSession();
    final events = <TurnProgressEvent>[];
    final sub = runner.progressEvents.listen(events.add);
    addTearDown(sub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(DeltaEvent('hello'));
      worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tu_p1', input: {'command': 'ls'}));
      await pumpEventQueue();
      worker.emit(ToolResultEvent(toolId: 'tu_p1', output: 'ok', isError: false));
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'progress test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    expect(events, hasLength(3));
    expect(events[0], isA<TextDeltaProgressEvent>());
    expect((events[0] as TextDeltaProgressEvent).text, 'hello');
    expect(events[1], isA<ToolStartedProgressEvent>());
    expect((events[1] as ToolStartedProgressEvent).toolName, 'bash');
    expect((events[1] as ToolStartedProgressEvent).toolCallCount, 1);
    expect(events[2], isA<ToolCompletedProgressEvent>());
    expect((events[2] as ToolCompletedProgressEvent).toolName, 'bash');
    expect((events[2] as ToolCompletedProgressEvent).isError, isFalse);
  });

  test('progressEvents snapshot has correct textLength and toolCallCount', () async {
    final session = await sessions.getOrCreateMainSession();
    final events = <TurnProgressEvent>[];
    final sub = runner.progressEvents.listen(events.add);
    addTearDown(sub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(DeltaEvent('abc')); // 3 chars
      worker.emit(DeltaEvent('de')); // +2 = 5 chars
      worker.emit(ToolUseEvent(toolName: 'read', toolId: 'tu_s1', input: {}));
      await pumpEventQueue();
      worker.emit(ToolResultEvent(toolId: 'tu_s1', output: 'ok', isError: false));
      worker.emit(ToolUseEvent(toolName: 'write', toolId: 'tu_s2', input: {}));
      await pumpEventQueue();
      worker.emit(ToolResultEvent(toolId: 'tu_s2', output: 'ok', isError: false));
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'snapshot test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    // 2 deltas + 2 tool starts + 2 tool completes = 6 events
    expect(events, hasLength(6));

    // First delta: textLength=3, toolCallCount=0
    expect(events[0].snapshot.textLength, 3);
    expect(events[0].snapshot.toolCallCount, 0);

    // Second delta: textLength=5, toolCallCount=0
    expect(events[1].snapshot.textLength, 5);
    expect(events[1].snapshot.toolCallCount, 0);

    // First tool started: toolCallCount=1
    expect(events[2].snapshot.toolCallCount, 1);
    expect(events[2].snapshot.textLength, 5);

    // First tool completed: toolCallCount=1
    expect(events[3].snapshot.toolCallCount, 1);

    // Second tool started: toolCallCount=2
    expect(events[4].snapshot.toolCallCount, 2);

    // Second tool completed: toolCallCount=2
    expect(events[5].snapshot.toolCallCount, 2);
    expect(events[5].snapshot.textLength, 5);
  });

  test('progressEvents not emitted for unrelated events (SystemInitEvent)', () async {
    final session = await sessions.getOrCreateMainSession();
    final events = <TurnProgressEvent>[];
    final sub = runner.progressEvents.listen(events.add);
    addTearDown(sub.cancel);

    unawaited(() async {
      await worker.turnInvoked;
      worker.emit(SystemInitEvent(contextWindow: 200000));
      worker.emit(DeltaEvent('only'));
      worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
    }());

    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'init event test'},
    ]);
    await runner.waitForOutcome(session.id, turnId);

    expect(events, hasLength(1));
    expect(events[0], isA<TextDeltaProgressEvent>());
    expect((events[0] as TextDeltaProgressEvent).text, 'only');
  });

  // ---------------------------------------------------------------------------
  // Stall-timeout wiring — regression for 2026-04-24 E2E issue #9 where the
  // plan-review turn hung silently for 27 minutes while a Codex sub-agent
  // waited on shell verification. The stall monitor is supposed to surface
  // that silence; these tests pin the wiring so a regression flips from a
  // 75-minute E2E failure to a <2-second unit failure.
  // ---------------------------------------------------------------------------
  group('stall timeout', () {
    test('stallAction=cancel produces TurnStatus.cancelled when turn emits no progress', () async {
      final stallRunner = _buildRunner(
        harness: worker,
        messages: messages,
        workspaceDir: workspaceDir,
        sessions: sessions,
        turnState: turnState,
        kvService: kvService,
        stallTimeout: const Duration(milliseconds: 200),
        stallAction: TurnProgressAction.cancel,
        turnMonitorTimerFactory: turnMonitorTime.create,
        turnMonitorNow: turnMonitorTime.now,
      );

      // Never complete the worker turn — it's the hung-sub-agent case.
      // The turn invocation awaits indefinitely; only the stall monitor
      // surfaces the silence.
      final session = await sessions.getOrCreateMainSession();

      final turnId = await stallRunner.startTurn(session.id, [
        {'role': 'user', 'content': 'stall'},
      ]);
      await worker.turnInvoked;
      await turnMonitorTime.elapseAsync(const Duration(milliseconds: 200));

      final outcome = await stallRunner
          .waitForOutcome(session.id, turnId)
          .timeout(const Duration(seconds: 5), onTimeout: () => fail('Stall action=cancel did not cancel the turn'));

      expect(outcome.status, TurnStatus.cancelled);
      expect(stallRunner.isActive(session.id), isFalse);
    });

    test('stallAction=warn lets the turn complete normally once progress resumes', () async {
      final stallRunner = _buildRunner(
        harness: worker,
        messages: messages,
        workspaceDir: workspaceDir,
        sessions: sessions,
        turnState: turnState,
        kvService: kvService,
        stallTimeout: const Duration(milliseconds: 150),
        stallAction: TurnProgressAction.warn,
        turnMonitorTimerFactory: turnMonitorTime.create,
        turnMonitorNow: turnMonitorTime.now,
      );

      unawaited(() async {
        await worker.turnInvoked;
        await turnMonitorTime.elapseAsync(const Duration(milliseconds: 250));
        worker.emit(DeltaEvent('finally some progress'));
        worker.completeSuccess(turnResult(inputTokens: 1, outputTokens: 1));
      }());

      final session = await sessions.getOrCreateMainSession();
      final turnId = await stallRunner.startTurn(session.id, [
        {'role': 'user', 'content': 'warn only'},
      ]);

      final outcome = await stallRunner.waitForOutcome(session.id, turnId).timeout(const Duration(seconds: 5));

      expect(outcome.status, TurnStatus.completed);
      expect(outcome.responseText, 'finally some progress');
    });

    test('stallAction=cancel emits TurnStallProgressEvent before cancelling', () async {
      final stallRunner = _buildRunner(
        harness: worker,
        messages: messages,
        workspaceDir: workspaceDir,
        sessions: sessions,
        turnState: turnState,
        kvService: kvService,
        stallTimeout: const Duration(milliseconds: 120),
        stallAction: TurnProgressAction.cancel,
        turnMonitorTimerFactory: turnMonitorTime.create,
        turnMonitorNow: turnMonitorTime.now,
      );

      final stallEvents = <TurnStallProgressEvent>[];
      final sub = stallRunner.progressEvents.listen((event) {
        if (event is TurnStallProgressEvent) stallEvents.add(event);
      });
      addTearDown(sub.cancel);

      final session = await sessions.getOrCreateMainSession();
      final turnId = await stallRunner.startTurn(session.id, [
        {'role': 'user', 'content': 'stall with event'},
      ]);
      await worker.turnInvoked;
      await turnMonitorTime.elapseAsync(const Duration(milliseconds: 120));

      await stallRunner.waitForOutcome(session.id, turnId).timeout(const Duration(seconds: 5));

      expect(stallEvents, isNotEmpty, reason: 'stall monitor must emit TurnStallProgressEvent before cancelling');
      expect(stallEvents.first.action, 'cancel');
      expect(stallEvents.first.stallTimeout.inMilliseconds, greaterThanOrEqualTo(120));
    });
  });
}
