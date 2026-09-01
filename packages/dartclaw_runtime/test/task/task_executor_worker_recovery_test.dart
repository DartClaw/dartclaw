import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

void main() {
  test('worker creation failure leaves tasks queued and retries once per profile on each poll', () async {
    final primaryWorker = FakeTaskWorker();
    final context = WorkflowTaskExecutorTestContext(primaryWorker);
    await context.setUp(tempPrefix: 'dartclaw_worker_recovery_test_');
    addTearDown(() => context.tearDown(workerDispose: primaryWorker.dispose));

    final behavior = BehaviorFileService(workspaceDir: context.workspaceDir);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: context.messages,
      behavior: behavior,
      sessions: context.sessions,
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final poolWorker = FakeTaskWorker()..responseText = 'recovered';
    addTearDown(poolWorker.dispose);
    final taskRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: poolWorker,
      messages: context.messages,
      behavior: behavior,
      sessions: context.sessions,
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    var creationAttempts = 0;
    var workerAvailable = false;
    final executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primaryRunner,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      createWorker: (_) async {
        creationAttempts++;
        if (!workerAvailable) throw const WorkerCreationException('restricted profile unavailable');
        return taskRunner;
      },
    );
    addTearDown(executions.dispose);
    final executor = context.harness.buildWorkflowExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
    );
    addTearDown(executor.stop);

    for (final id in ['task-worker-unavailable', 'task-worker-unavailable-2']) {
      await context.tasks.create(
        id: id,
        title: 'Unavailable worker',
        description: 'Remain queued until the required worker profile is available.',
        provider: 'claude',
        autoStart: true,
      );
    }

    expect(await executor.pollOnce(), isFalse);
    expect(creationAttempts, 1);
    expect((await context.tasks.get('task-worker-unavailable'))!.status, TaskStatus.queued);
    expect((await context.tasks.get('task-worker-unavailable-2'))!.status, TaskStatus.queued);
    expect(await executor.pollOnce(), isFalse);
    expect(creationAttempts, 2, reason: 'the unavailable profile is retried once on the next poll');

    workerAvailable = true;
    expect(await executor.pollOnce(), isTrue);
    await executor.drain();
    expect((await context.tasks.get('task-worker-unavailable'))!.status, TaskStatus.review);
    expect(executions.snapshot.activeWorkers, 0);
    expect(executions.snapshot.availableWorkers, 1);
  });
}
