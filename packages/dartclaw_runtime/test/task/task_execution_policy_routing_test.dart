import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProjectService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskConfig;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
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
  late Database taskDatabase;
  late SqliteTaskRepository taskRepository;

  setUp(() async {
    worker = FakeTaskWorker();
    harness = TaskExecutorTestHarness(worker);
    await harness.setUp(
      tempPrefix: 'dartclaw_policy_routing_',
      taskRepositoryFactory: (database) {
        taskDatabase = database;
        return taskRepository = SqliteTaskRepository(database);
      },
    );
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
    Map<String, dynamic> configJson = const {},
  }) => harness.tasks.create(
    id: id,
    title: id,
    description: 'Routing probe.',
    provider: provider,
    autoStart: true,
    securityProfile: securityProfile,
    configJson: {
      ...configJson,
      if (!configJson.containsKey(WorkflowTaskConfig.needsWorktree)) WorkflowTaskConfig.needsWorktree: false,
    },
  );

  ExecutionPolicy policyFor(String taskId) => requests.firstWhere((request) => request.taskId == taskId).policy;

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

  test('a pre-upgrade research row fails before any execution request', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: tasksOnHost());
    addTearDown(executor.stop);
    await harness.tasks.create(
      id: 'legacy-research',
      title: 'Legacy research',
      description: 'Persisted before upgrade.',
      autoStart: true,
    );
    taskDatabase.execute('UPDATE tasks SET type = ? WHERE id = ?', ['research', 'legacy-research']);

    expect(await executor.pollOnce(), isTrue);

    final task = (await harness.tasks.get('legacy-research'))!;
    expect(task.status, TaskStatus.failed);
    expect(task.configJson['errorSummary'], allOf(contains('research'), contains('securityProfile')));
    expect(requests, isEmpty);
  });

  test('a pre-upgrade coding row without a worktree declaration fails before execution', () async {
    final executor = harness.buildWorkflowExecutor(turnManager: recordingTurns(), policyResolver: tasksOnHost());
    addTearDown(executor.stop);
    await harness.tasks.create(
      id: 'legacy-coding',
      title: 'Legacy coding',
      description: 'Persisted before upgrade.',
      autoStart: true,
      configJson: const {},
    );
    taskDatabase.execute('UPDATE tasks SET type = ? WHERE id = ?', ['coding', 'legacy-coding']);

    expect(await executor.pollOnce(), isTrue);

    final task = (await harness.tasks.get('legacy-coding'))!;
    expect(task.status, TaskStatus.failed);
    expect(task.configJson['errorSummary'], allOf(contains('coding'), contains('needsWorktree')));
    expect(requests, isEmpty);
  });

  test('pre-upgrade research rows fail before missing, cloning, or errored project preparation', () async {
    final projects = FakeProjectService(
      projects: [
        cloningProject(id: 'cloning'),
        erroredProject(id: 'errored'),
      ],
      includeLocalProjectInGetAll: false,
    );
    final executor = harness.buildWorkflowExecutor(
      turnManager: recordingTurns(),
      policyResolver: tasksOnHost(),
      projectService: projects,
    );
    addTearDown(executor.stop);
    for (final projectId in const ['missing', 'cloning', 'errored']) {
      await harness.tasks.create(
        id: 'legacy-$projectId',
        title: 'Legacy $projectId project row',
        description: 'Persisted before upgrade.',
        projectId: projectId,
        autoStart: true,
      );
      taskDatabase.execute('UPDATE tasks SET type = ? WHERE id = ?', ['research', 'legacy-$projectId']);
    }

    expect(await executor.pollOnce(), isTrue);
    expect(requests, isEmpty);
    expect(projects.getCalls, isEmpty);
    for (final projectId in const ['missing', 'cloning', 'errored']) {
      final task = (await harness.tasks.get('legacy-$projectId'))!;
      expect(task.status, TaskStatus.failed, reason: projectId);
      expect(task.configJson['errorSummary'], contains('securityProfile explicitly'), reason: projectId);
    }
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
