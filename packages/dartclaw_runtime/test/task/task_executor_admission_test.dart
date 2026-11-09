import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskEventService;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

/// Coordinator admission runs before a worker is leased and can reject a task
/// for reasons the poll loop must own: global turn cap, governance budget and
/// loop detection. The coordinator here is real; only admission is scripted.
void main() {
  late FakeTaskWorker worker;
  late WorkflowTaskExecutorTestContext context;
  late InMemoryTaskEventService eventService;
  late int admissionAttempts;

  setUp(() async {
    worker = FakeTaskWorker();
    context = WorkflowTaskExecutorTestContext(worker);
    await context.setUp(tempPrefix: 'dartclaw_task_admission_test_');
    addTearDown(() => context.tearDown(workerDispose: worker.dispose));
    eventService = InMemoryTaskEventService();
    admissionAttempts = 0;
  });

  TaskExecutor buildExecutor({
    required Future<void> Function(ExecutionRequest request) admit,
    void Function(String)? release,
    ProjectService? projectService,
  }) {
    final executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 2},
      admitExecution: (request) {
        admissionAttempts++;
        return admit(request);
      },
      releaseAdmission: release ?? (_) {},
      createWorker: (request) async => TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: context.messages,
        behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
        sessions: context.sessions,
        providerId: request.providerId,
        executionPolicy: request.policy,
      ),
    );
    addTearDown(executions.dispose);
    final executor = context.harness.buildWorkflowExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      projectService: projectService,
      eventRecorder: TaskEventRecorder(eventService: eventService),
    );
    addTearDown(executor.stop);
    return executor;
  }

  Future<void> createQueuedTask(String id) => context.tasks.create(
    id: id,
    title: id,
    description: 'Admission-gated task.',
    provider: 'claude',
    autoStart: true,
    maxRetries: 2,
  );

  test('global turn cap leaves tasks queued, attempts admission once per pass, and starts them once free', () async {
    final locks = SessionLockManager(maxParallel: 1);
    await locks.acquire('chat-session');
    final executor = buildExecutor(admit: (request) => locks.acquire(request.sessionId), release: locks.release);
    await createQueuedTask('task-a');
    await createQueuedTask('task-b');

    expect(await executor.pollOnce(), isFalse);

    expect(admissionAttempts, 1, reason: 'the cap is global: a second attempt in the same pass fails identically');
    expect((await context.tasks.get('task-a'))!.status, TaskStatus.queued);
    expect((await context.tasks.get('task-b'))!.status, TaskStatus.queued);
    expect(await eventService.listForTask('task-a', kind: TaskEventKind.taskError), isEmpty);
    expect(await eventService.listForTask('task-b', kind: TaskEventKind.taskError), isEmpty);

    locks.release('chat-session');
    expect(await executor.pollOnce(), isTrue);
    await executor.drain();

    expect((await context.tasks.get('task-a'))!.status, TaskStatus.review);
    expect(admissionAttempts, 3, reason: 'the next pass retries admission rather than caching the refusal');
  });

  test('busy admission does not stop non-acquire work for later tasks in the same pass', () async {
    final locks = SessionLockManager(maxParallel: 1);
    await locks.acquire('chat-session');
    final executor = buildExecutor(
      admit: (request) => locks.acquire(request.sessionId),
      release: locks.release,
      projectService: fakeProjectServiceFor(erroredProject()),
    );
    await createQueuedTask('task-busy');
    await context.tasks.create(
      id: 'task-refused',
      title: 'Errored project',
      description: 'Fails during preparation, before any acquisition.',
      provider: 'claude',
      autoStart: true,
      projectId: 'my-app',
    );

    await executor.pollOnce();

    expect(admissionAttempts, 1);
    expect((await context.tasks.get('task-busy'))!.status, TaskStatus.queued);
    expect((await context.tasks.get('task-refused'))!.status, TaskStatus.failed);
  });

  test('loop detected at admission fails the task without retrying', () async {
    final executor = buildExecutor(
      admit: (request) async => throw LoopDetectedException(
        'turn chain too deep',
        LoopDetection(
          mechanism: LoopMechanism.turnChainDepth,
          sessionId: request.sessionId,
          message: 'turn chain too deep',
        ),
      ),
    );
    await createQueuedTask('task-loop');

    await executor.pollOnce();
    await executor.drain();

    final failed = (await context.tasks.get('task-loop'))!;
    expect(failed.status, TaskStatus.failed);
    expect(failed.retryCount, 0, reason: 'loop detection is non-retryable even with maxRetries configured');
    expect(failed.configJson['errorSummary'], 'Loop detected: turn chain too deep');
  });

  test('exhausted budget at admission fails the task without retrying', () async {
    final executor = buildExecutor(
      admit: (_) async => throw const BudgetExhaustedException(tokensUsed: 1200, budget: 1000),
    );
    await createQueuedTask('task-budget');

    await executor.pollOnce();
    await executor.drain();

    final failed = (await context.tasks.get('task-budget'))!;
    expect(failed.status, TaskStatus.failed);
    expect(failed.retryCount, 0, reason: 'a queued task would auto-start at the daily reset and spend unattended');
    expect(failed.configJson['errorSummary'], contains('Daily token budget exhausted: 1200/1000'));
  });

  /// Real loop detection (`abort` after one consecutive non-human turn) and a
  /// real global rate limiter behind the coordinator's admission.
  ({TaskExecutor executor, ExecutionCoordinator executions}) buildLoopGovernedExecutor({
    required int poolSize,
    required SessionLockManager locks,
    required SlidingWindowRateLimiter rateLimiter,
    required FakeTaskWorker primaryWorker,
    required FakeTaskWorker Function(ExecutionRequest request) workerFor,
  }) {
    TurnRunner runnerFor(AgentHarness harness, {String providerId = 'claude', ExecutionPolicy? policy}) => TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: harness,
      messages: context.messages,
      behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
      sessions: context.sessions,
      providerId: providerId,
      executionPolicy: policy ?? const ExecutionPolicy.host(),
      lockManager: locks,
      globalRateLimiter: rateLimiter,
      loopDetector: LoopDetector(
        config: const LoopDetectionConfig(
          enabled: true,
          maxConsecutiveTurns: 1,
          maxTokensPerMinute: 999999,
          velocityWindowMinutes: 2,
          maxConsecutiveIdenticalToolCalls: 999,
          action: LoopAction.abort,
        ),
      ),
      loopAction: LoopAction.abort,
    );
    final primary = runnerFor(primaryWorker);
    final executions = ExecutionCoordinator(
      providerCapacities: {'claude': poolSize},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async =>
          runnerFor(workerFor(request), providerId: request.providerId, policy: request.policy),
    );
    addTearDown(executions.dispose);
    final executor = context.harness.buildWorkflowExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      eventRecorder: TaskEventRecorder(eventService: eventService),
    );
    addTearDown(executor.stop);
    return (executor: executor, executions: executions);
  }

  test('a task polled behind a full global cap accrues no loop depth and runs once the slot frees', () async {
    final locks = SessionLockManager(maxParallel: 1);
    await locks.acquire('chat-session');
    final primaryWorker = FakeTaskWorker();
    addTearDown(primaryWorker.dispose);
    final built = buildLoopGovernedExecutor(
      poolSize: 2,
      locks: locks,
      rateLimiter: SlidingWindowRateLimiter(limit: 100, window: const Duration(minutes: 5)),
      primaryWorker: primaryWorker,
      workerFor: (_) => worker,
    );
    final executor = built.executor;
    await createQueuedTask('task-polled');

    for (var poll = 0; poll < 3; poll++) {
      expect(await executor.pollOnce(), isFalse);
    }

    final waiting = (await context.tasks.get('task-polled'))!;
    expect(waiting.status, TaskStatus.queued, reason: 'a task that never ran is not a loop');
    expect(await eventService.listForTask('task-polled', kind: TaskEventKind.taskError), isEmpty);

    locks.release('chat-session');
    expect(await executor.pollOnce(), isTrue);
    await executor.drain();

    expect((await context.tasks.get('task-polled'))!.status, TaskStatus.review);
  });

  test(
    'a task polled behind a full worker pool stays queued, burns no rate token, and runs once a slot frees',
    () async {
      final primaryWorker = FakeTaskWorker();
      final holderWorker = FakeTaskWorker();
      addTearDown(primaryWorker.dispose);
      addTearDown(holderWorker.dispose);
      final rateLimiter = SlidingWindowRateLimiter(limit: 100, window: const Duration(minutes: 5));
      final built = buildLoopGovernedExecutor(
        poolSize: 1,
        locks: SessionLockManager(maxParallel: 4),
        rateLimiter: rateLimiter,
        primaryWorker: primaryWorker,
        workerFor: (request) => request.sessionId == 'pool-holder' ? holderWorker : worker,
      );
      // An empty tool policy makes the holder's worker execution-scoped, so it is torn down on release.
      final holder = await built.executions.acquire(
        const ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: 'claude',
          policy: ExecutionPolicy.host(),
          sessionId: 'pool-holder',
          isHumanInput: true,
          allowedTools: [],
        ),
      );
      expect(holder, isNotNull);
      final eventsBeforePolls = rateLimiter.currentCount('global');
      await createQueuedTask('task-polled');

      for (var poll = 0; poll < 3; poll++) {
        expect(await built.executor.pollOnce(), isFalse, reason: 'poll $poll: no permit, so no work');
      }

      final waiting = (await context.tasks.get('task-polled'))!;
      expect(waiting.status, TaskStatus.queued, reason: 'a task that never ran is not a loop');
      expect(await eventService.listForTask('task-polled', kind: TaskEventKind.taskError), isEmpty);
      expect(
        rateLimiter.currentCount('global'),
        eventsBeforePolls,
        reason: 'a poll that finds no permit must not consume the global turn rate',
      );

      await holder!.release();
      expect(await built.executor.pollOnce(), isTrue);
      await built.executor.drain();

      expect((await context.tasks.get('task-polled'))!.status, TaskStatus.review);
      expect(
        rateLimiter.currentCount('global'),
        eventsBeforePolls + 1,
        reason: 'the one admitted run is the only event',
      );
    },
  );
}
