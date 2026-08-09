import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../execution_coordinator_test_support.dart';
import '../turn_runner_test_support.dart';

void main() {
  late ExecutionCoordinator executions;
  late EventBus eventBus;
  late RunnerObserver observer;

  setUp(() async {
    final runners = [
      FakeTurnRunner(),
      FakeTurnRunner(providerId: 'codex', supportsCachedTokens: true),
      FakeTurnRunner(),
    ];
    executions = coordinatorForRunners(runners);
    eventBus = EventBus();
    observer = RunnerObserver(executions: executions, eventBus: eventBus);
    final codex = await executions.acquire(_request(executions, providerId: 'codex', sessionId: 'codex'));
    final claude = await executions.acquire(_request(executions, providerId: 'claude', sessionId: 'claude'));
    await codex!.release();
    await claude!.release();
    await pumpEventQueue();
  });

  tearDown(() async {
    await observer.dispose();
    await executions.dispose();
    await eventBus.dispose();
  });

  test('initializes metrics for primary and lazily created workers', () {
    final metrics = observer.metrics;
    expect(metrics, hasLength(3));
    expect(metrics[0].runnerId, 0);
    expect(metrics[0].role, 'primary');
    expect(metrics[0].providerId, 'claude');
    expect(metrics[0].state, RunnerState.idle);
    expect(metrics[1].runnerId, 1);
    expect(metrics[1].role, 'worker');
    expect(metrics[1].providerId, 'codex');
    expect(metrics[2].runnerId, 2);
    expect(metrics[2].role, 'worker');
    expect(metrics[2].providerId, 'claude');
  });

  test('metricsFor returns null for out-of-range index', () {
    expect(observer.metricsFor(-1), isNull);
    expect(observer.metricsFor(99), isNull);
  });

  test('capacityStatus delegates to ExecutionCoordinator', () {
    final status = observer.capacityStatus;
    expect(status.runnerCount, 3);
    expect(status.configured, 2);
    expect(status.active, 0);
    expect(status.available, 2);
  });

  test('records each primary turn outcome exactly once', () async {
    final lease = await executions.acquire(
      _request(executions, providerId: 'claude', sessionId: 'primary-metrics', surface: ExecutionSurface.interactive),
    );
    final outcome = await _completeTurn(lease!, inputTokens: 20, outputTokens: 7);
    expect(outcome.status, TurnStatus.completed, reason: outcome.errorMessage);
    expect(outcome.inputTokens, 20);
    expect(outcome.outputTokens, 7);

    await lease.runner!.waitForOutcome(outcome.sessionId, outcome.turnId);
    await pumpEventQueue();

    final metrics = observer.metricsFor(0)!;
    expect(metrics.turnsCompleted, 1);
    expect(metrics.tokensConsumed, 27);
    await lease.release();
  });

  test('records each worker task outcome exactly once', () async {
    final lease = await executions.acquire(
      _request(executions, providerId: 'codex', sessionId: 'codex', taskId: 'task-metrics'),
    );
    final outcome = await _completeTurn(
      lease!,
      inputTokens: 11,
      outputTokens: 4,
      cacheReadTokens: 5,
      cacheWriteTokens: 2,
      toolFailures: const [false, true],
    );

    await lease.runner!.waitForOutcome(outcome.sessionId, outcome.turnId);
    final failedOutcome = await _completeTurn(lease, inputTokens: 3, outputTokens: 2, fail: true);
    await lease.runner!.waitForOutcome(failedOutcome.sessionId, failedOutcome.turnId);
    await pumpEventQueue();

    final metrics = observer.metricsFor(1)!;
    expect(metrics.turnsCompleted, 2);
    expect(metrics.tokensConsumed, 20);
    expect(metrics.errorCount, 1);
    expect(metrics.cacheReadTokens, 5);
    expect(metrics.cacheWriteTokens, 2);
    expect(metrics.totalToolCalls, 2);
    expect(metrics.failedToolCalls, 1);
    await lease.release();
  });

  test('removes disposed runners from current metrics during fingerprint churn', () async {
    final churnExecutions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      createWorker: (request) async => FakeTurnRunner(providerId: request.providerId, profileId: request.profileId),
    );
    final churnEvents = EventBus();
    final churnObserver = RunnerObserver(executions: churnExecutions, eventBus: churnEvents);
    addTearDown(() async {
      await churnObserver.dispose();
      await churnExecutions.dispose();
      await churnEvents.dispose();
    });

    for (var index = 0; index < 5; index++) {
      final lease = await churnExecutions.acquire(
        _request(churnExecutions, providerId: 'claude', sessionId: 'churn-$index', profileId: 'profile-$index'),
      );
      await lease!.release();
      await pumpEventQueue();

      expect(churnExecutions.runners, hasLength(1));
      expect(churnObserver.metrics, hasLength(1));
      expect(churnObserver.metrics.single.runnerId, lease.runnerId);
    }
  });

  test('capacityChanges reports a queued lease before it becomes active', () async {
    final active = await executions.acquire(_request(executions, providerId: 'claude', sessionId: 'active'));
    final queuedChange = observer.capacityChanges.firstWhere((status) => status.active == 1 && status.queued == 1);

    final queuedFuture = executions.acquire(_request(executions, providerId: 'claude', sessionId: 'queued'));
    final queuedStatus = await queuedChange;
    expect(queuedStatus.available, 1);

    final activatedChange = observer.capacityChanges.firstWhere((status) => status.active == 1 && status.queued == 0);
    await active!.release();
    final queued = await queuedFuture;
    final activatedStatus = await activatedChange;
    expect(activatedStatus.available, 1);

    await queued!.release();
  });

  test('fires RunnerStateChangedEvent when a lease is acquired', () async {
    final events = <RunnerStateChangedEvent>[];
    eventBus.on<RunnerStateChangedEvent>().listen(events.add);

    final lease = await executions.acquire(
      _request(executions, providerId: 'codex', sessionId: 'codex', taskId: 'task-1'),
    );
    final activeLease = lease!;
    addTearDown(activeLease.release);

    await pumpEventQueue();
    expect(events, hasLength(1));
    expect(events[0].runnerId, 1);
    expect(events[0].state, 'busy');
    expect(events[0].currentTaskId, 'task-1');

    await activeLease.release();
  });

  test('fires RunnerStateChangedEvent when a lease is released', () async {
    final events = <RunnerStateChangedEvent>[];
    eventBus.on<RunnerStateChangedEvent>().listen(events.add);

    final lease = await executions.acquire(
      _request(executions, providerId: 'claude', sessionId: 'claude', taskId: 'task-2'),
    );
    final activeLease = lease!;
    addTearDown(activeLease.release);
    await pumpEventQueue();
    await activeLease.release();

    await pumpEventQueue();
    expect(events.last.runnerId, 2);
    expect(events.last.state, 'idle');
    expect(events.last.currentTaskId, isNull);
  });

  test('toJson produces correct structure', () async {
    final lease = await executions.acquire(
      _request(executions, providerId: 'codex', sessionId: 'session-y', taskId: 'task-x'),
    );
    addTearDown(lease!.release);
    await _completeTurn(lease, inputTokens: 500, outputTokens: 300);
    final json = observer.metricsFor(1)!.toJson();
    expect(json['runnerId'], 1);
    expect(json['role'], 'worker');
    expect(json['providerId'], 'codex');
    expect(json['state'], 'busy');
    expect(json['currentTaskId'], 'task-x');
    expect(json['currentSessionId'], 'session-y');
    expect(json['tokensConsumed'], 800);
    expect(json['turnsCompleted'], 1);
    expect(json['errorCount'], 0);
  });
}

ExecutionRequest _request(
  ExecutionCoordinator executions, {
  required String providerId,
  required String sessionId,
  String profileId = 'workspace',
  ExecutionSurface surface = ExecutionSurface.task,
  String? taskId,
}) {
  return ExecutionRequest(
    surface: surface,
    providerId: providerId,
    sessionId: sessionId,
    fingerprint: executions.fingerprintFor(providerId, profileId),
    taskId: taskId,
  );
}

Future<TurnOutcome> _completeTurn(
  ExecutionLease lease, {
  required int inputTokens,
  required int outputTokens,
  int cacheReadTokens = 0,
  int cacheWriteTokens = 0,
  List<bool> toolFailures = const [],
  bool fail = false,
}) async {
  final runner = lease.runner!;
  final turnId = lease.admissionOwned
      ? await runner.reserveAdmittedTurn(lease.request.sessionId)
      : await runner.reserveTurn(lease.request.sessionId);
  final harness = runner.harness as FakeAgentHarness;
  unawaited(() async {
    await harness.turnInvoked;
    for (var index = 0; index < toolFailures.length; index++) {
      final toolId = 'tool-$index';
      harness.emit(ToolUseEvent(toolName: 'tool-$index', toolId: toolId, input: const {}));
      harness.emit(ToolResultEvent(toolId: toolId, output: 'result', isError: toolFailures[index]));
    }
    await pumpEventQueue();
    final result = turnResult(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedInputTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
    );
    if (fail) {
      result['stop_reason'] = 'error';
      result['error'] = 'failed';
    }
    harness.completeSuccess(result);
  }());
  runner.executeTurn(lease.request.sessionId, turnId, const [
    {'role': 'user', 'content': 'metrics'},
  ]);
  final outcome = await runner.waitForOutcome(lease.request.sessionId, turnId);
  await runner.waitForExecutionSettled(lease.request.sessionId, turnId);
  await pumpEventQueue();
  return outcome;
}
