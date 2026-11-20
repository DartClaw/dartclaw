import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskConfig;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

/// Identityless background work consumes the one shared resolver.
///
/// Equivalent coding work entering through an ordinary task, workflow-owned
/// one-shot, or scheduled task carries the scalar task-lane fallback, while an
/// explicit profile selects its container.
void main() {
  late TaskExecutorTestHarness harness;
  late FakeTaskWorker worker;
  late List<ExecutionRequest> requests;
  late InMemoryTaskRepository taskRepository;

  setUp(() async {
    worker = FakeTaskWorker();
    harness = TaskExecutorTestHarness(worker);
    taskRepository = InMemoryTaskRepository();
    await harness.setUp(tempPrefix: 'dartclaw_policy_routing_', taskRepositoryFactory: (_) => taskRepository);
    requests = [];
  });

  tearDown(() async {
    await harness.tearDown();
    await worker.dispose();
  });

  /// Container-enabled deployment whose task lane opts out to the host.
  ExecutionPolicyResolver tasksOnHost() => ExecutionPolicyResolver(
    config: DartclawConfig.defaults().copyWith(
      container: const ContainerConfig(enabled: true),
      tasks: const TaskConfig(execution: ExecutionMode.host),
    ),
    availableContainerProfiles: const {'workspace', 'restricted'},
  );

  /// A coordinator that records every admitted request and then refuses to
  /// build a worker, so each task stops at admission and the assertion is about
  /// the policy the entry point carried, not about turn execution.
  TurnManager recordingTurns() {
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {
        'claude': 4,
        'claude-coding': 1,
        'claude-writing': 1,
        'claude-analysis': 1,
        'claude-automation': 1,
        'claude-custom': 1,
      },
      admitExecution: (request) async => requests.add(request),
      releaseAdmission: (_) {},
      createWorker: (_) async => throw const WorkerCreationException('probe: no worker in this topology'),
    );
    addTearDown(coordinator.dispose);
    return TurnManager.fromCoordinator(
      turnLimits: const TurnLimitsConfig.defaults(),
      coordinator: coordinator,
      sessions: harness.sessions,
    );
  }

  Future<void> createTask(
    String id, {
    String provider = 'claude',
    String? securityProfile,
    int maxRetries = 0,
    Map<String, dynamic> configJson = const {},
  }) => harness.tasks.create(
    id: id,
    title: id,
    description: 'Routing probe.',
    provider: provider,
    autoStart: true,
    securityProfile: securityProfile,
    maxRetries: maxRetries,
    configJson: {
      ...configJson,
      if (!configJson.containsKey(WorkflowTaskConfig.needsWorktree)) WorkflowTaskConfig.needsWorktree: false,
    },
  );

  ExecutionPolicy policyFor(String taskId) => requests.firstWhere((request) => request.taskId == taskId).policy;

  for (final retryCount in [0, 1]) {
    test('workspace container prompt carries the toolchain note (retry $retryCount)', () async {
      worker.responseText = 'Completed.';
      final executor = harness.buildWorkflowExecutor(
        policyResolver: ExecutionPolicyResolver.forStandalonePolicy(const ExecutionPolicy.container('workspace')),
      );
      addTearDown(executor.stop);
      await createTask('workspace-prompt', maxRetries: 1);
      await harness.tasks.updateFields('workspace-prompt', retryCount: retryCount);

      await executor.pollOnce();
      await executor.drain();

      final task = (await harness.tasks.get('workspace-prompt'))!;
      expect(task.status, TaskStatus.review, reason: task.configJson.toString());
      final prompt = (await harness.messages.getMessages(task.sessionId!)).first.content;
      expect(prompt, contains('### Container Toolchains'));
      expect(prompt, contains('no direct network access'));
      expect(prompt, contains('container.image'));
      expect(prompt, contains('default image provides none'));
      expect(prompt, contains('report the missing binary by name'));
      expect(prompt, contains('Stop work that requires the missing toolchain'));
      expect(prompt, contains('Do not install or download a toolchain'));
      expect(prompt, contains('docs/guide/security.md#language-toolchains-in-the-agent-image'));
      expect(prompt.contains('## Retry Context'), retryCount > 0);
    });
  }

  test('workspace push-back prompt carries no toolchain note', () async {
    worker.responseText = 'Completed.';
    final executor = harness.buildWorkflowExecutor(
      policyResolver: ExecutionPolicyResolver.forStandalonePolicy(const ExecutionPolicy.container('workspace')),
    );
    addTearDown(executor.stop);
    await createTask('workspace-feedback', configJson: const {'pushBackComment': 'Explain the result.'});

    await executor.pollOnce();
    await executor.drain();

    final task = (await harness.tasks.get('workspace-feedback'))!;
    final prompt = (await harness.messages.getMessages(task.sessionId!)).first.content;
    expect(prompt, contains('## Push-back Feedback'));
    expect(prompt, isNot(contains('### Container Toolchains')));
  });

  test('host and restricted prompts carry no toolchain note', () async {
    worker.responseText = 'Completed.';
    for (final policy in [const ExecutionPolicy.host(), const ExecutionPolicy.container('restricted')]) {
      final executor = harness.buildWorkflowExecutor(
        policyResolver: ExecutionPolicyResolver.forStandalonePolicy(policy),
      );
      addTearDown(executor.stop);
      final id = 'prompt-${policy.containerProfile ?? 'host'}';
      await createTask(id, securityProfile: policy.containerProfile);

      await executor.pollOnce();
      await executor.drain();

      final task = (await harness.tasks.get(id))!;
      expect(task.status, TaskStatus.review, reason: task.configJson.toString());
      final prompt = (await harness.messages.getMessages(task.sessionId!)).first.content;
      expect(
        prompt,
        '## Task: $id\n\nRouting probe.\n\n### Working Directory\n`${harness.workspaceDir}`\n\n'
        'Use this directory as the only workspace for this task.',
      );
    }
  });

  test('an ordinary task uses the configured host fallback', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: tasksOnHost());
    addTearDown(executor.stop);
    await createTask('ordinary-task');

    await executor.pollOnce();

    expect(policyFor('ordinary-task'), const ExecutionPolicy.host());
  });

  test('a scheduled task takes the same fallback as any other task', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: tasksOnHost());
    addTearDown(executor.stop);
    // A scheduled task definition reaches execution as an ordinary Task row;
    // its scheduling origin does not select a different execution policy.
    await createTask('scheduled-task');

    await executor.pollOnce();

    expect(policyFor('scheduled-task'), const ExecutionPolicy.host());
  });

  test('S04 an explicit restricted profile reaches the container worker', () async {
    final resolver = ExecutionPolicyResolver(
      config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
      availableContainerProfiles: const {'workspace', 'restricted'},
    );
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: resolver);
    addTearDown(executor.stop);
    await createTask('restricted-task', securityProfile: 'restricted');

    await executor.pollOnce();

    expect(policyFor('restricted-task'), const ExecutionPolicy.container('restricted'));
  });

  test('an undeclared task uses workspace placement without a profile', () async {
    final resolver = ExecutionPolicyResolver(
      config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
      availableContainerProfiles: const {'workspace', 'restricted'},
    );
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: resolver);
    addTearDown(executor.stop);
    await createTask('task', provider: 'claude');

    await executor.pollOnce();

    expect(policyFor('task'), const ExecutionPolicy.container('workspace'));
  });

  test('an unavailable declared profile is refused before worker admission', () async {
    final resolver = ExecutionPolicyResolver(
      config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
      availableContainerProfiles: const {'workspace'},
    );
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: resolver);
    addTearDown(executor.stop);
    await createTask('unavailable-profile', securityProfile: 'restricted');

    expect(await executor.pollOnce(), isTrue);
    expect(requests, isEmpty);
    final task = (await harness.tasks.get('unavailable-profile'))!;
    expect(task.status, TaskStatus.failed);
    expect(task.configJson['errorSummary'], allOf(contains('restricted'), contains('no container manager')));
    expect(await executor.pollOnce(), isFalse);
  });

  test('present malformed and unknown profile declarations are refused before worker admission', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: tasksOnHost());
    addTearDown(executor.stop);
    for (final entry in <String, Object?>{'non-string': 7, 'blank': '', 'unknown': 'privileged'}.entries) {
      await taskRepository.insert(
        Task(
          id: entry.key,
          title: entry.key,
          description: 'Persisted declaration probe.',
          status: TaskStatus.queued,
          configJson: {'securityProfile': entry.value},
          createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
        ),
      );
    }

    expect(await executor.pollOnce(), isTrue);
    expect(requests, isEmpty);
    for (final entry in <String, String>{
      'non-string': 'securityProfile must be a non-empty string',
      'blank': 'securityProfile must be a non-empty string',
      'unknown': 'unknown container profile',
    }.entries) {
      final task = (await harness.tasks.get(entry.key))!;
      expect(task.status, TaskStatus.failed, reason: entry.key);
      expect(task.configJson['errorSummary'], contains(entry.value), reason: entry.key);
    }
    expect(await executor.pollOnce(), isFalse);
  });

  test('an explicit workspace declaration is refused when containers are disabled', () async {
    final resolver = ExecutionPolicyResolver(config: DartclawConfig.defaults(), availableContainerProfiles: const {});
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: resolver);
    addTearDown(executor.stop);
    await createTask('workspace-disabled', securityProfile: 'workspace');

    expect(await executor.pollOnce(), isTrue);
    expect(requests, isEmpty);
    final task = (await harness.tasks.get('workspace-disabled'))!;
    expect(task.status, TaskStatus.failed);
    expect(task.configJson['errorSummary'], allOf(contains('workspace'), contains('has no host equivalent')));
    expect(await executor.pollOnce(), isFalse);
  });

  test('standalone composition uses the same task-policy authority', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns());
    addTearDown(executor.stop);
    await createTask('standalone-default');
    await createTask('standalone-profile', securityProfile: 'workspace');

    expect(await executor.pollOnce(), isTrue);
    expect(policyFor('standalone-default'), const ExecutionPolicy.host());
    expect(requests.where((request) => request.taskId == 'standalone-profile'), isEmpty);
    expect((await harness.tasks.get('standalone-profile'))!.status, TaskStatus.failed);
    expect(await executor.pollOnce(), isFalse);
  });

  test('a task that stays queued keeps its effective policy on the next attempt', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: tasksOnHost());
    addTearDown(executor.stop);
    await createTask('queued-task');

    await executor.pollOnce();
    expect((await harness.tasks.get('queued-task'))!.status, TaskStatus.queued);
    requests.clear();
    await executor.pollOnce();

    expect(policyFor('queued-task'), const ExecutionPolicy.host());
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

    test('workspace workflow one-shot carries the toolchain note', () async {
      workflowWorker
        ..structuredOutputSupported = true
        ..structuredOutput = {
          'outputs': <String, dynamic>{},
          'step_outcome': {'outcome': 'succeeded', 'reason': 'Completed.'},
        };
      final executor = context.buildExecutor(
        policyResolver: ExecutionPolicyResolver.forStandalonePolicy(const ExecutionPolicy.container('workspace')),
      );
      addTearDown(executor.stop);
      await context.tasks.create(
        id: 'workflow-toolchain-prompt',
        title: 'Workflow prompt',
        description: 'Run the project tests.',
        autoStart: true,
        configJson: const {WorkflowTaskConfig.needsWorktree: false},
      );
      await context.seedWorkflowExecution('workflow-toolchain-prompt', workflowRunId: 'workflow-prompt-run');

      await executor.pollOnce();
      await executor.drain();

      final task = (await context.tasks.get('workflow-toolchain-prompt'))!;
      final prompt = (await context.messages.getMessages(task.sessionId!)).first.content;
      expect(prompt, contains('### Container Toolchains'));
      expect(prompt, contains('container.image'));
      expect(prompt, contains('docs/guide/security.md#language-toolchains-in-the-agent-image'));
    });

    test('a workflow one-shot carries the same host policy as an ordinary task', () async {
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 4},
        admitExecution: (request) async => workflowRequests.add(request),
        releaseAdmission: (_) {},
        createWorker: (_) async => throw const WorkerCreationException('probe: no worker in this topology'),
      );
      addTearDown(coordinator.dispose);
      final executor = context.buildExecutor(
        turnManager: TurnManager.fromCoordinator(
          turnLimits: const TurnLimitsConfig.defaults(),
          coordinator: coordinator,
          sessions: context.sessions,
        ),
        policyResolver: tasksOnHost(),
      );
      addTearDown(executor.stop);

      await context.tasks.create(
        id: 'workflow-task',
        title: 'Workflow coding',
        description: 'Routing probe.',
        provider: 'claude',
        configJson: const {WorkflowTaskConfig.needsWorktree: true},
        autoStart: true,
      );
      await context.seedWorkflowExecution('workflow-task', workflowRunId: 'run-1');

      await executor.pollOnce();

      final workflow = workflowRequests.single;
      expect(workflow.surface, ExecutionSurface.workflow, reason: 'the workflow path is genuinely exercised');
      expect(
        workflow.policy,
        const ExecutionPolicy.host(),
        reason: 'workflow-owned work applies the same task-lane fallback as an ordinary task',
      );
    });

    test('S02 workflow requests carry only that step artifacts and merge-resolve variables', () async {
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 4},
        admitExecution: (request) async => workflowRequests.add(request),
        releaseAdmission: (_) {},
        createWorker: (_) async => throw const WorkerCreationException('probe: request captured'),
      );
      addTearDown(coordinator.dispose);
      final executor = context.buildExecutor(
        turnManager: TurnManager.fromCoordinator(
          turnLimits: const TurnLimitsConfig.defaults(),
          coordinator: coordinator,
          sessions: context.sessions,
        ),
        policyResolver: tasksOnHost(),
      );
      addTearDown(executor.stop);

      await context.tasks.create(
        id: 'workflow-construction-inputs',
        title: 'Workflow construction inputs',
        description: 'Carry this step contract to its worker.',
        provider: 'claude',
        autoStart: true,
        configJson: const {
          WorkflowTaskConfig.needsWorktree: true,
          WorkflowTaskConfig.mergeResolveEnv: {'ANDTHEN_REPORT_PATH': '/tmp/step/report.md'},
          WorkflowTaskConfig.stepArtifactsEnv: {'DARTCLAW_STEP_ARTIFACTS_DIR': '/tmp/step'},
        },
      );
      await context.seedWorkflowExecution('workflow-construction-inputs', workflowRunId: 'run-inputs');

      await executor.pollOnce();

      final request = workflowRequests.single;
      expect(request.artifactsDir, '/tmp/step');
      expect(request.spawnEnvironment, {
        'ANDTHEN_REPORT_PATH': '/tmp/step/report.md',
        'DARTCLAW_STEP_ARTIFACTS_DIR': '/tmp/step',
      });
    });

    test('S03 creates the artifacts directory before constructing a container worker', () async {
      final artifactsDir = p.join(context.tempDir.path, 'absent', 'step-artifacts');
      bool? existedAtWorkerConstruction;
      ExecutionPolicy? constructedPolicy;
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 4},
        admitExecution: (_) async {},
        releaseAdmission: (_) {},
        createWorker: (request) async {
          constructedPolicy = request.policy;
          existedAtWorkerConstruction = Directory(request.artifactsDir!).existsSync();
          throw const WorkerCreationException('probe: creation order captured');
        },
      );
      addTearDown(coordinator.dispose);
      final executor = context.buildExecutor(
        turnManager: TurnManager.fromCoordinator(
          turnLimits: const TurnLimitsConfig.defaults(),
          coordinator: coordinator,
          sessions: context.sessions,
        ),
        policyResolver: ExecutionPolicyResolver(
          config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
          availableContainerProfiles: const {'workspace', 'restricted'},
        ),
      );
      addTearDown(executor.stop);

      await context.tasks.create(
        id: 'workflow-artifacts-order',
        title: 'Workflow artifacts order',
        description: 'Create the directory before worker construction.',
        provider: 'claude',
        autoStart: true,
        configJson: {
          WorkflowTaskConfig.needsWorktree: true,
          WorkflowTaskConfig.stepArtifactsEnv: {'DARTCLAW_STEP_ARTIFACTS_DIR': artifactsDir},
        },
      );
      await context.seedWorkflowExecution('workflow-artifacts-order', workflowRunId: 'run-artifacts-order');

      await executor.pollOnce();

      expect(constructedPolicy?.isContainer, isTrue);
      expect(existedAtWorkerConstruction, isTrue);
    });
  });
}
