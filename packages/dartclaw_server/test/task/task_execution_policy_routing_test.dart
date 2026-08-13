import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

/// Identityless background work consumes the one shared resolver.
///
/// Covers Acceptance Scenario S04: equivalent coding work entering through an
/// ordinary task, a workflow-owned one-shot, and a scheduled task all carry the
/// configured host fallback, while an unoverridden research task stays
/// containerized.
void main() {
  late TaskExecutorTestHarness harness;
  late FakeTaskWorker worker;
  late List<ExecutionRequest> requests;

  setUp(() async {
    worker = FakeTaskWorker();
    harness = TaskExecutorTestHarness(worker);
    await harness.setUp(tempPrefix: 'dartclaw_policy_routing_');
    requests = [];
  });

  tearDown(() async {
    await harness.tearDown();
    await worker.dispose();
  });

  /// Container-enabled deployment whose coding task type opts out to the host.
  ExecutionPolicyResolver codingOnHost() => ExecutionPolicyResolver(
    config: DartclawConfig.defaults().copyWith(
      container: const ContainerConfig(enabled: true),
      tasks: const TaskConfig(execution: {TaskType.coding: ExecutionMode.host}),
    ),
    availableContainerProfiles: const {'workspace', 'restricted'},
  );

  /// A coordinator that records every admitted request and then refuses to
  /// build a worker, so each task stops at admission and the assertion is about
  /// the policy the entry point carried, not about turn execution.
  TurnManager recordingTurns() {
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'claude': 4},
      admitExecution: (request) async => requests.add(request),
      releaseAdmission: (_) {},
      createWorker: (_) async => throw const WorkerCreationException('probe: no worker in this topology'),
    );
    addTearDown(coordinator.dispose);
    return TurnManager.fromCoordinator(coordinator: coordinator, sessions: harness.sessions);
  }

  Future<void> createTask(String id, TaskType type, {Map<String, dynamic> configJson = const {}}) =>
      harness.tasks.create(
        id: id,
        title: id,
        description: 'Routing probe.',
        type: type,
        provider: 'claude',
        autoStart: true,
        configJson: configJson,
      );

  ExecutionPolicy policyFor(String taskId) => requests.firstWhere((request) => request.taskId == taskId).policy;

  test('S04 an ordinary coding task uses the configured host fallback', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: codingOnHost());
    addTearDown(executor.stop);
    await createTask('coding-task', TaskType.coding);

    await executor.pollOnce();

    expect(policyFor('coding-task'), const ExecutionPolicy.host());
  });

  test('S04 a scheduled coding task takes the same fallback as any other task', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: codingOnHost());
    addTearDown(executor.stop);
    // A scheduled task definition reaches execution as an ordinary Task row —
    // agent identity is never persisted on the task, only its type.
    await createTask('scheduled-coding-task', TaskType.coding);

    await executor.pollOnce();

    expect(policyFor('scheduled-coding-task'), const ExecutionPolicy.host());
  });

  test('S04 an unoverridden research task stays containerized', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: codingOnHost());
    addTearDown(executor.stop);
    await createTask('research-task', TaskType.research);

    await executor.pollOnce();

    expect(policyFor('research-task'), const ExecutionPolicy.container('restricted'));
  });

  test('a task that stays queued keeps its effective policy on the next attempt', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: codingOnHost());
    addTearDown(executor.stop);
    await createTask('coding-task', TaskType.coding);

    await executor.pollOnce();
    expect((await harness.tasks.get('coding-task'))!.status, TaskStatus.queued);
    requests.clear();
    await executor.pollOnce();

    expect(policyFor('coding-task'), const ExecutionPolicy.host());
  });
  group('S04 workflow-owned execution', () {
    late WorkflowTaskExecutorTestContext context;
    late FakeTaskWorker workflowWorker;
    late List<ExecutionRequest> workflowRequests;

    setUp(() async {
      workflowWorker = FakeTaskWorker();
      context = WorkflowTaskExecutorTestContext(workflowWorker);
      await context.setUp(tempPrefix: 'dartclaw_policy_routing_wf_');
      workflowRequests = [];
    });

    tearDown(() => context.tearDown(workerDispose: workflowWorker.dispose));

    test('a workflow one-shot carries the same host policy as an ordinary coding task', () async {
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 4},
        admitExecution: (request) async => workflowRequests.add(request),
        releaseAdmission: (_) {},
        createWorker: (_) async => throw const WorkerCreationException('probe: no worker in this topology'),
      );
      addTearDown(coordinator.dispose);
      final executor = context.buildExecutor(
        turnManager: TurnManager.fromCoordinator(coordinator: coordinator, sessions: context.sessions),
        policyResolver: codingOnHost(),
      );
      addTearDown(executor.stop);

      await context.tasks.create(
        id: 'workflow-coding-task',
        title: 'Workflow coding',
        description: 'Routing probe.',
        type: TaskType.coding,
        provider: 'claude',
        autoStart: true,
      );
      await context.seedWorkflowExecution('workflow-coding-task', workflowRunId: 'run-1');

      await executor.pollOnce();

      final workflow = workflowRequests.single;
      expect(workflow.surface, ExecutionSurface.workflow, reason: 'the workflow path is genuinely exercised');
      expect(
        workflow.policy,
        const ExecutionPolicy.host(),
        reason: 'workflow-owned work applies the same task-type fallback as an ordinary task',
      );
    });
  });
}
