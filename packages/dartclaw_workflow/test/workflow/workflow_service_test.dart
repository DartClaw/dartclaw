@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        KvService,
        MessageService,
        OutputConfig,
        SessionService,
        SessionType,
        Task,
        TaskArtifact,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowApprovalPolicy,
        WorkflowApprovalResolvedEvent,
        WorkflowDefinition,
        WorkflowExecutionCursor,
        WorkflowGitStrategy,
        WorkflowGitWorktreeMode,
        WorkflowGitWorktreeStrategy,
        WorkflowLoop,
        MergeResolveConfig,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowWorktreeBinding,
        WorkflowStep,
        WorkflowTaskService,
        WorkflowVariable,
        WorkflowGitContext,
        WorkflowPersistencePorts,
        WorkflowStartResolution,
        WorkflowServiceOptions,
        WorkflowTurnAdapter;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskCancellationSubscriber, TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show
        SqliteAgentExecutionRepository,
        SqliteExecutionRepositoryTransactor,
        SqliteTaskRepository,
        SqliteWorkflowRunRepository,
        SqliteWorkflowStepExecutionRepository,
        openTaskDbInMemory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show BashProcessOwner, WorkflowService;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway, FakeProcess, FakeTurnManager, flushAsync;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart' show standardTurnAdapter;
import 'workflow_service_test_support.dart';

void main() {
  late WorkflowServiceTestHarness harness;
  late Directory tempDir;
  late TaskService taskService;
  late SqliteWorkflowRunRepository repository;
  late EventBus eventBus;
  late WorkflowService workflowService;

  setUp(() {
    harness = WorkflowServiceTestHarness()..setUp();
    tempDir = harness.tempDir;
    taskService = harness.taskService;
    repository = harness.repository;
    eventBus = harness.eventBus;
    workflowService = harness.workflowService;
  });

  tearDown(() async {
    await harness.tearDown(currentService: workflowService);
  });

  WorkflowDefinition makeDefinition({
    List<WorkflowStep>? steps,
    Map<String, WorkflowVariable> variables = const {},
    WorkflowGitStrategy? gitStrategy,
  }) {
    return harness.makeDefinition(steps: steps, variables: variables, gitStrategy: gitStrategy);
  }

  WorkflowService lifecycleOnlyService({
    WorkflowTurnAdapter? turnAdapter,
    WorkflowGitContext? gitContext,
    WorkflowServiceOptions options = const WorkflowServiceOptions(),
    Map<String, Future<void>>? debugSeedActiveExecutors,
  }) {
    return harness.lifecycleOnlyService(
      turnAdapter: turnAdapter,
      gitContext: gitContext,
      options: options,
      debugSeedActiveExecutors: debugSeedActiveExecutors,
    );
  }

  void autoCompleteNewTasks([List<String>? titles]) {
    harness.autoCompleteNewTasks(titles);
  }

  Future<void> waitForRunStatus(String runId, WorkflowRunStatus expected) async {
    await harness.waitForRunStatus(runId, expected);
  }

  void writeContextSnapshot(String runId, Map<String, dynamic> contextJson) {
    harness.writeContextSnapshot(runId, contextJson);
  }

  Future<WorkflowRun> insertRun({
    required String id,
    WorkflowDefinition? definition,
    WorkflowRunStatus status = WorkflowRunStatus.running,
    int? currentStepIndex,
    Map<String, String> variablesJson = const {},
    Map<String, dynamic> contextJson = const {},
    WorkflowExecutionCursor? executionCursor,
    WorkflowWorktreeBinding? workflowWorktree,
    String? errorMessage,
    bool writeContextFile = false,
  }) async {
    return harness.insertRun(
      id: id,
      definition: definition,
      status: status,
      currentStepIndex: currentStepIndex,
      variablesJson: variablesJson,
      contextJson: contextJson,
      executionCursor: executionCursor,
      workflowWorktree: workflowWorktree,
      errorMessage: errorMessage,
      writeContextFile: writeContextFile,
    );
  }

  test('start() creates run in pending→running, fires status events', () async {
    final statusEvents = <WorkflowRunStatusChangedEvent>[];
    eventBus.on<WorkflowRunStatusChangedEvent>().listen(statusEvents.add);

    final definition = makeDefinition();
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {});
    await Future<void>.delayed(Duration.zero); // Let EventBus dispatch async events.

    expect(run.status, equals(WorkflowRunStatus.running));
    expect(run.definitionName, equals('test-workflow'));
    expect(statusEvents.any((e) => e.newStatus == WorkflowRunStatus.running), isTrue);
  });

  test('start() persists initial context.json to disk', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {});

    final contextFile = File(p.join(tempDir.path, 'workflows', 'runs', run.id, 'context.json'));
    expect(contextFile.existsSync(), isTrue);
  });

  test('start() persists explicit approvals policy on the run context', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {}, approvals: WorkflowApprovalPolicy.autoOnStall);

    expect(run.contextJson['_workflow.approvals'], 'auto-on-stall');
    final contextFile = File(p.join(tempDir.path, 'workflows', 'runs', run.id, 'context.json'));
    final persisted = jsonDecode(contextFile.readAsStringSync()) as Map<String, dynamic>;
    expect((persisted['data'] as Map<String, dynamic>)['_workflow.approvals'], 'auto-on-stall');
  });

  test('start(inline: true) overrides the git strategy to inline and discards integration-only settings', () async {
    // S01/S02 [OC01][OC02]: the single inline seam in start() yields
    // integrationBranch:false + worktree inline and drops promotion/publish/
    // cleanup/merge_resolve, which are no-ops without an integration branch.
    final definition = makeDefinition(
      gitStrategy: const WorkflowGitStrategy(
        integrationBranch: true,
        worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.shared),
        promotion: 'merge',
        publish: true,
        cleanup: true,
        mergeResolve: MergeResolveConfig(enabled: true),
      ),
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {}, inline: true);

    final effective = WorkflowDefinition.fromJson(run.definitionJson).gitStrategy!;
    expect(effective.integrationBranch, isFalse);
    expect(effective.worktreeMode, equals('inline'));
    expect(effective.promotion, isNull);
    expect(effective.publish, isNull);
    expect(effective.cleanup, isNull);
    expect(effective.toJson().containsKey('merge_resolve'), isFalse);
  });

  test('start() without inline leaves the authored git strategy untouched', () async {
    // S04 [OC01]: non-inline runs keep integrationBranch + worktree as authored.
    final definition = makeDefinition(
      gitStrategy: const WorkflowGitStrategy(
        integrationBranch: true,
        worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.shared),
        promotion: 'merge',
      ),
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {});

    final effective = WorkflowDefinition.fromJson(run.definitionJson).gitStrategy!;
    expect(effective.integrationBranch, isTrue);
    expect(effective.worktreeMode, equals('shared'));
    expect(effective.promotion, equals('merge'));
  });

  test('start() uses service approval default when no invocation override is supplied', () async {
    final service = lifecycleOnlyService(
      options: const WorkflowServiceOptions(approvalPolicyDefault: WorkflowApprovalPolicy.auto),
    );
    addTearDown(service.dispose);
    final definition = makeDefinition(steps: []);

    final run = await service.start(definition, {});

    expect(run.contextJson['_workflow.approvals'], 'auto');
  });

  test('start() applies required variable values', () async {
    final definition = makeDefinition(
      variables: {'topic': const WorkflowVariable(required: true, description: 'The topic')},
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {'topic': 'Dart programming'});
    expect(run.variablesJson['topic'], equals('Dart programming'));
  });

  test('start() reports all missing required variables in one error, excluding defaulted ones', () async {
    // S03 shape: FEATURE + TARGET missing, MODE required-with-default satisfied.
    final definition = makeDefinition(
      variables: {
        'FEATURE': const WorkflowVariable(required: true, description: 'feature'),
        'TARGET': const WorkflowVariable(required: true, description: 'target'),
        'MODE': const WorkflowVariable(required: true, description: 'mode', defaultValue: 'auto'),
      },
    );

    expect(
      () => workflowService.start(definition, const {}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          allOf(contains('FEATURE'), contains('TARGET'), isNot(contains('MODE'))),
        ),
      ),
    );
  });

  test('start() does not throw for a required variable that has a default value', () async {
    final definition = makeDefinition(
      variables: {'MODE': const WorkflowVariable(required: true, description: 'mode', defaultValue: 'auto')},
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, const {});
    expect(run.variablesJson['MODE'], equals('auto'));
  });

  test('start() treats an out-of-band projectId as satisfying a required PROJECT variable', () async {
    // Parity with the server route, which injects PROJECT before validating —
    // a required PROJECT supplied via projectId must not error standalone.
    final definition = makeDefinition(
      variables: {'PROJECT': const WorkflowVariable(required: true, description: 'project')},
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, const {}, projectId: 'my-app');
    expect(run.variablesJson['PROJECT'], equals('my-app'));
  });

  test('start() injects projectId into PROJECT when the workflow declares that variable', () async {
    final definition = makeDefinition(
      variables: {'PROJECT': const WorkflowVariable(required: false, description: 'Target project')},
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, const {}, projectId: 'my-app');

    expect(run.variablesJson['PROJECT'], equals('my-app'));
  });

  test('start() resolves omitted BRANCH to symbolic HEAD before first step context is built', () async {
    final localRepo = Directory.systemTemp.createTempSync('wf_service_local_repo_');
    addTearDown(() {
      if (localRepo.existsSync()) {
        localRepo.deleteSync(recursive: true);
      }
    });
    await Process.run('git', ['init'], workingDirectory: localRepo.path);
    await Process.run('git', ['checkout', '-b', 'develop'], workingDirectory: localRepo.path);
    File(p.join(localRepo.path, 'README.md')).writeAsStringSync('local');
    await Process.run('git', ['add', '.'], workingDirectory: localRepo.path);
    await Process.run(
      'git',
      ['commit', '-m', 'init', '--no-gpg-sign'],
      workingDirectory: localRepo.path,
      environment: {
        'GIT_AUTHOR_NAME': 'Test',
        'GIT_AUTHOR_EMAIL': 'test@test.com',
        'GIT_COMMITTER_NAME': 'Test',
        'GIT_COMMITTER_EMAIL': 'test@test.com',
      },
    );

    workflowService = lifecycleOnlyService(
      turnAdapter: standardTurnAdapter(
        turnId: 'turn-id',
        resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
          final head = await Process.run('git', [
            'symbolic-ref',
            '--quiet',
            '--short',
            'HEAD',
          ], workingDirectory: localRepo.path);
          return WorkflowStartResolution(projectId: '_local', branch: (head.stdout as String).trim());
        },
      ),
    );
    autoCompleteNewTasks();

    final definition = makeDefinition(
      variables: const {
        'PROJECT': WorkflowVariable(required: false),
        'BRANCH': WorkflowVariable(required: false, defaultValue: 'main'),
      },
      steps: const [
        WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
      ],
    );
    final run = await workflowService.start(definition, const {});

    expect(run.variablesJson['PROJECT'], equals('_local'));
    expect(run.variablesJson['BRANCH'], equals('develop'));
  });

  test('start() fails preflight before creating run or coding task', () async {
    workflowService = lifecycleOnlyService(
      turnAdapter: standardTurnAdapter(
        turnId: 'turn-id',
        resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
          throw ArgumentError('Ref "missing/ref" not found');
        },
      ),
    );
    final definition = makeDefinition(
      variables: const {'PROJECT': WorkflowVariable(required: false), 'BRANCH': WorkflowVariable(required: false)},
      steps: const [
        WorkflowStep(id: 'coding-step', name: 'Coding', taskType: WorkflowTaskType.agent, prompts: ['Implement']),
      ],
    );

    await expectLater(
      workflowService.start(definition, const {'PROJECT': 'my-app', 'BRANCH': 'missing/ref'}),
      throwsA(isA<ArgumentError>()),
    );
    expect(await workflowService.list(), isEmpty);
    expect(await taskService.list(), isEmpty);
  });

  test('lifecycleOnly start() rejects agent workflows before creating run or task', () async {
    workflowService = lifecycleOnlyService();
    final definition = makeDefinition(
      steps: const [
        WorkflowStep(id: 'coding-step', name: 'Coding', taskType: WorkflowTaskType.agent, prompts: ['Implement']),
      ],
    );

    await expectLater(
      workflowService.start(definition, const {}),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('WorkflowPersistencePorts'))),
    );
    expect(await workflowService.list(), isEmpty);
    expect(await taskService.list(), isEmpty);
  });

  test('start() throws when required variable missing', () async {
    final definition = makeDefinition(
      variables: {'topic': const WorkflowVariable(required: true, description: 'Required')},
    );

    expect(
      () => workflowService.start(definition, {}),
      throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('topic'))),
    );
  });

  test('pause() transitions running to paused', () async {
    final definition = makeDefinition(
      steps: [
        // Long running step — we pause before it completes.
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Long step']),
      ],
    );

    final run = await workflowService.start(definition, {});
    final paused = await workflowService.pause(run.id);

    expect(paused.status, equals(WorkflowRunStatus.paused));
    final stored = await workflowService.get(run.id);
    expect(stored?.status, equals(WorkflowRunStatus.paused));
  });

  test('pause() throws when workflow not running', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();
    final run = await workflowService.start(definition, {});
    await waitForRunStatus(run.id, WorkflowRunStatus.completed);

    expect(() => workflowService.pause(run.id), throwsA(isA<StateError>()));
  });

  test('resume() transitions paused to running', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    final paused = await workflowService.pause(run.id);

    autoCompleteNewTasks();
    final resumed = await workflowService.resume(paused.id);

    expect(resumed.status, equals(WorkflowRunStatus.running));
  });

  test('repository worktree binding round-trips on workflow_runs', () async {
    await insertRun(
      id: 'run-binding',
      definition: makeDefinition(
        steps: const [
          WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
        ],
      ),
    );
    const binding = WorkflowWorktreeBinding(
      key: 'run-binding',
      path: '/tmp/worktrees/wf-run-binding',
      branch: 'dartclaw/workflow/runbinding/integration',
      workflowRunId: 'run-binding',
    );

    await repository.setWorktreeBinding('run-binding', binding);

    final stored = await repository.getById('run-binding');
    final rebound = await repository.getWorktreeBinding('run-binding');
    expect(stored?.workflowWorktree?.toJson(), binding.toJson());
    expect(rebound?.toJson(), binding.toJson());
  });

  test('resume() hydrates persisted workflow worktree binding before respawn', () async {
    final hydrated = <WorkflowWorktreeBinding>[];
    workflowService = lifecycleOnlyService(
      gitContext: WorkflowGitContext(
        gitPort: FakeGitGateway(),
        hydrateBinding: (binding) {
          expect(binding.workflowRunId, 'run-hydrate');
          hydrated.add(binding);
        },
      ),
    );

    await insertRun(
      id: 'run-hydrate',
      status: WorkflowRunStatus.paused,
      definition: makeDefinition(
        steps: const [
          WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
        ],
      ),
      workflowWorktree: const WorkflowWorktreeBinding(
        key: 'run-hydrate',
        path: '/tmp/worktrees/wf-run-hydrate',
        branch: 'dartclaw/workflow/runhydrate/integration',
        workflowRunId: 'run-hydrate',
      ),
    );
    autoCompleteNewTasks();

    await workflowService.resume('run-hydrate');

    expect(hydrated, hasLength(1));
    expect(hydrated.single.key, 'run-hydrate');
    expect(hydrated.single.path, '/tmp/worktrees/wf-run-hydrate');
  });

  test('resume() hydrates every persisted workflow worktree binding for the run', () async {
    final hydrated = <WorkflowWorktreeBinding>[];
    workflowService = lifecycleOnlyService(
      gitContext: WorkflowGitContext(
        gitPort: FakeGitGateway(),
        hydrateBinding: (binding) {
          expect(binding.workflowRunId, 'run-hydrate-many');
          hydrated.add(binding);
        },
      ),
    );

    await insertRun(
      id: 'run-hydrate-many',
      status: WorkflowRunStatus.paused,
      definition: makeDefinition(
        steps: const [
          WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
        ],
      ),
    );
    await repository.setWorktreeBinding(
      'run-hydrate-many',
      const WorkflowWorktreeBinding(
        key: 'run-hydrate-many',
        path: '/tmp/worktrees/wf-run-hydrate-many',
        branch: 'dartclaw/workflow/runhydrate/integration',
        workflowRunId: 'run-hydrate-many',
      ),
    );
    await repository.setWorktreeBinding(
      'run-hydrate-many',
      const WorkflowWorktreeBinding(
        key: 'run-hydrate-many:map:0',
        path: '/tmp/worktrees/wf-run-hydrate-many-map-0',
        branch: 'dartclaw/workflow/runhydrate/story-0',
        workflowRunId: 'run-hydrate-many',
      ),
    );
    autoCompleteNewTasks();

    await workflowService.resume('run-hydrate-many');

    expect(hydrated.map((binding) => binding.key), containsAll(['run-hydrate-many', 'run-hydrate-many:map:0']));
  });

  test('resume() throws when persisted workflow worktree binding runId mismatches the run', () async {
    await insertRun(
      id: 'run-mismatch',
      status: WorkflowRunStatus.paused,
      workflowWorktree: const WorkflowWorktreeBinding(
        key: 'run-mismatch',
        path: '/tmp/worktrees/wf-run-mismatch',
        branch: 'dartclaw/workflow/runmismatch/integration',
        workflowRunId: 'run-other',
      ),
    );

    await expectLater(workflowService.resume('run-mismatch'), throwsA(isA<StateError>()));
  });

  test('resume() throws when workflow not paused', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();
    final run = await workflowService.start(definition, {});

    expect(() => workflowService.resume(run.id), throwsA(isA<StateError>()));
  });

  test('cancel() transitions running to cancelled', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});

    await workflowService.cancel(run.id);

    final stored = await workflowService.get(run.id);
    expect(stored?.status, equals(WorkflowRunStatus.cancelled));
  });

  test('cancel() transitions only the run non-terminal child tasks to cancelled', () async {
    final run = await insertRun(id: 'run-A', status: WorkflowRunStatus.running);
    await insertRun(id: 'run-B', status: WorkflowRunStatus.running);

    final queued = await taskService.create(
      id: 'run-a-queued',
      title: 'run A queued',
      description: 'x',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: run.id,
    );
    final running = await taskService.create(
      id: 'run-a-running',
      title: 'run A running',
      description: 'x',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: run.id,
    );
    await taskService.transition(running.id, TaskStatus.running, trigger: 'test');
    final accepted = await taskService.create(
      id: 'run-a-accepted',
      title: 'run A accepted',
      description: 'x',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: run.id,
    );
    await taskService.transition(accepted.id, TaskStatus.running, trigger: 'test');
    await taskService.transition(accepted.id, TaskStatus.review, trigger: 'test');
    await taskService.transition(accepted.id, TaskStatus.accepted, trigger: 'test');
    final otherRun = await taskService.create(
      id: 'run-b-running',
      title: 'run B running',
      description: 'x',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: 'run-B',
    );
    await taskService.transition(otherRun.id, TaskStatus.running, trigger: 'test');

    await workflowService.cancel(run.id);

    expect((await taskService.get(queued.id))?.status, TaskStatus.cancelled);
    expect((await taskService.get(running.id))?.status, TaskStatus.cancelled);
    expect((await taskService.get(accepted.id))?.status, TaskStatus.accepted);
    expect((await taskService.get(otherRun.id))?.status, TaskStatus.running);
  });

  test('cancel() transitions paused to cancelled', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    await workflowService.pause(run.id);

    await workflowService.cancel(run.id);

    final stored = await workflowService.get(run.id);
    expect(stored?.status, equals(WorkflowRunStatus.cancelled));
  });

  test('cancel() invokes workflow git cleanup after child tasks are cancelled', () async {
    final cleanupObservedNonTerminalCounts = <int>[];
    workflowService = lifecycleOnlyService(
      turnAdapter: standardTurnAdapter(
        turnId: 'turn-id',
        cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
          final tasks = await taskService.list();
          final remaining = tasks.where((task) => task.workflowRunId == runId && !task.status.terminal).length;
          cleanupObservedNonTerminalCounts.add(remaining);
        },
      ),
    );

    final run = await insertRun(
      id: 'cancel-order-run',
      status: WorkflowRunStatus.running,
      variablesJson: const {'PROJECT': 'my-app'},
    );
    final task = await taskService.create(
      id: 'cancel-order-task',
      title: 'cancel order task',
      description: 'x',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: run.id,
    );
    await taskService.transition(task.id, TaskStatus.running, trigger: 'test');

    await workflowService.cancel(run.id);

    expect((await taskService.get(task.id))?.status, TaskStatus.cancelled);
    expect(cleanupObservedNonTerminalCounts, equals([0]));
  });

  group('cancel() cleanup honors gitStrategy.cleanup', () {
    Future<bool?> cancelAndCapturePreserve(WorkflowGitStrategy? strategy) async {
      bool? observed;
      workflowService = lifecycleOnlyService(
        turnAdapter: standardTurnAdapter(
          turnId: 'turn-id',
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                observed = preserveWorktrees;
              },
        ),
      );
      final definition = WorkflowDefinition(
        name: 'test-workflow',
        description: 'cleanup config',
        gitStrategy: strategy,
        steps: const [
          WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['noop']),
        ],
      );
      final run = await insertRun(
        id: 'cancel-cleanup-${strategy?.cleanup ?? 'default'}',
        status: WorkflowRunStatus.running,
        variablesJson: const {'PROJECT': 'my-app'},
        definition: definition,
      );
      await workflowService.cancel(run.id);
      return observed;
    }

    for (final row in const [
      (name: 'default strategy', strategy: null, expected: false),
      (name: 'cleanup.enabled: true', strategy: WorkflowGitStrategy(cleanup: true), expected: false),
      (name: 'cleanup.enabled: false', strategy: WorkflowGitStrategy(cleanup: false), expected: true),
    ]) {
      test('${row.name} sets preserveWorktrees=${row.expected}', () async {
        expect(await cancelAndCapturePreserve(row.strategy), row.expected);
      });
    }
  });

  test('cancel() propagates to the active turn when the cancellation subscriber is installed', () async {
    final turns = FakeTurnManager();
    final subscriber = TaskCancellationSubscriber(tasks: taskService, turns: turns)..subscribe(eventBus);
    addTearDown(subscriber.dispose);

    final run = await insertRun(id: 'cancel-turn-run', status: WorkflowRunStatus.running);

    final task = await taskService.create(
      id: 'cancel-turn-task',
      title: 'cancel turn task',
      description: 'x',
      type: TaskType.research,
      autoStart: true,
      provider: 'codex',
      workflowRunId: run.id,
    );
    final running = await taskService.transition(task.id, TaskStatus.running, trigger: 'test');
    await taskService.updateFields(running.id, sessionId: 'session-cancel-turn');

    await workflowService.cancel(run.id);
    await Future<void>.delayed(Duration.zero);

    expect((await taskService.get(task.id))?.status, TaskStatus.cancelled);
    expect(turns.cancelTurnCallCount, 1);
    expect(turns.cancelledSessionIds, ['session-cancel-turn']);
  });

  test('dispose() cancels active-run tasks, leaves inactive-run tasks untouched, and drains executors', () async {
    final definition = makeDefinition();
    final runA = await workflowService.start(definition, {});
    final runB = await workflowService.start(definition, {});
    final inactive = await taskService.create(
      id: 'inactive-run-task',
      title: 'inactive run task',
      description: 'x',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: 'run-C',
    );

    Future<List<String>> taskIdsForRun(String runId) async {
      for (var attempt = 0; attempt < 20; attempt += 1) {
        final ids = (await taskService.listByWorkflowRunIds([runId])).map((task) => task.id).toList();
        if (ids.isNotEmpty) {
          return ids;
        }
        await Future<void>.delayed(Duration.zero);
      }
      return const [];
    }

    final runATasks = await taskIdsForRun(runA.id);
    final runBTasks = await taskIdsForRun(runB.id);
    expect(runATasks, isNotEmpty);
    expect(runBTasks, isNotEmpty);

    await workflowService.dispose();

    for (final taskId in [...runATasks, ...runBTasks]) {
      expect((await taskService.get(taskId))?.status, TaskStatus.cancelled);
    }
    expect((await taskService.get(inactive.id))?.status, TaskStatus.queued);
  });

  test('dispose() does not return until in-flight executor futures drain', () async {
    // Hold a controllable in-flight executor future in the drain set, then prove
    // dispose() blocks on `await Future.wait(_activeExecutors.values)`: if that
    // drain were removed, dispose would complete before the gate is released.
    final executorGate = Completer<void>();
    var executorDrained = false;
    final blockedExecutor = executorGate.future.then((_) => executorDrained = true);
    final service = lifecycleOnlyService(debugSeedActiveExecutors: {'run-blocked': blockedExecutor});

    var disposed = false;
    final disposeFuture = service.dispose().then((_) => disposed = true);

    await flushAsync();
    expect(executorDrained, isFalse, reason: 'gate not released yet');
    expect(disposed, isFalse, reason: 'dispose must await the in-flight executor before returning');

    executorGate.complete();
    await disposeFuture;

    expect(executorDrained, isTrue);
    expect(disposed, isTrue);
  });

  test('dispose() retains a timed-out Bash process when spawn identity is unavailable', () async {
    final process = FakeProcess(completeExitOnKill: true);
    final owner = BashProcessOwner()
      ..track(process)
      ..markCleanupPending(process);
    final service = WorkflowService.lifecycleOnly(
      repository: repository,
      taskService: taskService,
      messageService: harness.messageService,
      eventBus: eventBus,
      kvService: harness.kvService,
      dataDir: tempDir.path,
      debugBashProcessOwner: owner,
    );

    await service.dispose();

    expect(process.killCalled, isTrue);
    expect(owner.cleanupPendingProcesses, contains(process));
  });

  test('cancel() and dispose() use run-scoped task lookup instead of the full-table list path', () async {
    final recordingTasks = _RecordingWorkflowTaskService(taskService);
    workflowService = WorkflowService.lifecycleOnly(
      repository: repository,
      taskService: recordingTasks,
      messageService: harness.messageService,
      eventBus: eventBus,
      kvService: harness.kvService,
      dataDir: tempDir.path,
    );
    final run = await insertRun(id: 'run-A', status: WorkflowRunStatus.running);

    await workflowService.cancel(run.id);

    expect(recordingTasks.listCallCount, 0);
    expect(recordingTasks.listByWorkflowRunIdsCalls, [
      ['run-A'],
    ]);

    final disposeDb = openTaskDbInMemory();
    final disposeEventBus = EventBus();
    final disposeTaskRepository = SqliteTaskRepository(disposeDb);
    final disposeAgentExecutions = SqliteAgentExecutionRepository(disposeDb, eventBus: disposeEventBus);
    final disposeStepExecutions = SqliteWorkflowStepExecutionRepository(disposeDb);
    final disposeTransactor = SqliteExecutionRepositoryTransactor(disposeDb);
    final disposeTaskService = TaskService(
      disposeTaskRepository,
      agentExecutionRepository: disposeAgentExecutions,
      executionTransactor: disposeTransactor,
      eventBus: disposeEventBus,
    );
    final disposeRecordingTasks = _RecordingWorkflowTaskService(disposeTaskService);
    final disposeMessages = MessageService(baseDir: p.join(tempDir.path, 'dispose-sessions'));
    final disposeKv = KvService(filePath: p.join(tempDir.path, 'dispose-kv.json'));
    final disposeWorkflowService = WorkflowService(
      repository: SqliteWorkflowRunRepository(disposeDb),
      taskService: disposeRecordingTasks,
      messageService: disposeMessages,
      persistencePorts: WorkflowPersistencePorts(
        taskRepository: disposeTaskRepository,
        agentExecutionRepository: disposeAgentExecutions,
        workflowStepExecutionRepository: disposeStepExecutions,
        executionRepositoryTransactor: disposeTransactor,
      ),
      eventBus: disposeEventBus,
      kvService: disposeKv,
      dataDir: tempDir.path,
    );
    addTearDown(disposeWorkflowService.dispose);
    addTearDown(disposeTaskService.dispose);
    addTearDown(disposeMessages.dispose);
    addTearDown(disposeKv.dispose);
    addTearDown(disposeEventBus.dispose);
    addTearDown(disposeDb.close);

    final disposeRun = await disposeWorkflowService.start(makeDefinition(), {});
    await Future<void>.delayed(Duration.zero);

    await disposeWorkflowService.dispose();

    expect(disposeRecordingTasks.listCallCount, 0);
    expect(disposeRecordingTasks.listByWorkflowRunIdsCalls, [
      [disposeRun.id],
    ]);
  });

  test('dispose() snapshots active run ids before task lookup awaits', () async {
    final disposeDb = openTaskDbInMemory();
    final disposeEventBus = EventBus();
    final disposeTaskRepository = SqliteTaskRepository(disposeDb);
    final disposeAgentExecutions = SqliteAgentExecutionRepository(disposeDb, eventBus: disposeEventBus);
    final disposeStepExecutions = SqliteWorkflowStepExecutionRepository(disposeDb);
    final disposeTransactor = SqliteExecutionRepositoryTransactor(disposeDb);
    final disposeTaskService = TaskService(
      disposeTaskRepository,
      agentExecutionRepository: disposeAgentExecutions,
      executionTransactor: disposeTransactor,
      eventBus: disposeEventBus,
    );
    final lookupStarted = Completer<void>();
    final disposeRepository = SqliteWorkflowRunRepository(disposeDb);
    late WorkflowRun disposeRun;
    final disposeRecordingTasks = _RecordingWorkflowTaskService(
      disposeTaskService,
      beforeListByWorkflowRunIds: () async {
        if (!lookupStarted.isCompleted) {
          lookupStarted.complete();
        }
        for (var attempt = 0; attempt < 20; attempt += 1) {
          final stored = await disposeRepository.getById(disposeRun.id);
          if (stored?.status.terminal ?? false) {
            return;
          }
          await Future<void>.delayed(Duration.zero);
        }
      },
    );
    final disposeMessages = MessageService(baseDir: p.join(tempDir.path, 'dispose-snapshot-sessions'));
    final disposeKv = KvService(filePath: p.join(tempDir.path, 'dispose-snapshot-kv.json'));
    final disposeWorkflowService = WorkflowService(
      repository: disposeRepository,
      taskService: disposeRecordingTasks,
      messageService: disposeMessages,
      persistencePorts: WorkflowPersistencePorts(
        taskRepository: disposeTaskRepository,
        agentExecutionRepository: disposeAgentExecutions,
        workflowStepExecutionRepository: disposeStepExecutions,
        executionRepositoryTransactor: disposeTransactor,
      ),
      eventBus: disposeEventBus,
      kvService: disposeKv,
      dataDir: tempDir.path,
    );
    disposeEventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      try {
        await disposeTaskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
        await disposeTaskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
        await disposeTaskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
      } on StateError {
        // Dispose may cancel the task before the listener completes.
      }
    });
    addTearDown(disposeWorkflowService.dispose);
    addTearDown(disposeTaskService.dispose);
    addTearDown(disposeMessages.dispose);
    addTearDown(disposeKv.dispose);
    addTearDown(disposeEventBus.dispose);
    addTearDown(disposeDb.close);

    disposeRun = await disposeWorkflowService.start(makeDefinition(), {});

    final disposeFuture = disposeWorkflowService.dispose();
    await lookupStarted.future;
    await disposeFuture;

    expect(disposeRecordingTasks.listByWorkflowRunIdsCalls, [
      [disposeRun.id],
    ]);
  });

  test('dispose() promotes queued active-run tasks before cancelling after promotion conflicts', () async {
    for (final conflict in const [
      'state-error',
      'version-conflict',
      'stored-queued-version-conflict',
      'retry-running-version-conflict',
      'retry-queued-version-conflict',
    ]) {
      final disposeDb = openTaskDbInMemory();
      final disposeEventBus = EventBus();
      final taskEvents = <TaskStatusChangedEvent>[];
      final taskEventSub = disposeEventBus.on<TaskStatusChangedEvent>().listen(taskEvents.add);
      final disposeTaskRepository = SqliteTaskRepository(disposeDb);
      final disposeAgentExecutions = SqliteAgentExecutionRepository(disposeDb, eventBus: disposeEventBus);
      final disposeStepExecutions = SqliteWorkflowStepExecutionRepository(disposeDb);
      final disposeTransactor = SqliteExecutionRepositoryTransactor(disposeDb);
      final disposeTaskService = TaskService(
        disposeTaskRepository,
        agentExecutionRepository: disposeAgentExecutions,
        executionTransactor: disposeTransactor,
        eventBus: disposeEventBus,
      );
      var promotionAttempts = 0;
      final disposeRecordingTasks = _RecordingWorkflowTaskService(
        disposeTaskService,
        beforeTransition: (taskId, newStatus) async {
          if (newStatus == TaskStatus.running) {
            promotionAttempts += 1;
          }
          if (promotionAttempts == 1 && newStatus == TaskStatus.running) {
            if (conflict == 'stored-queued-version-conflict' ||
                conflict == 'retry-running-version-conflict' ||
                conflict == 'retry-queued-version-conflict') {
              throw Exception('simulated queued version conflict');
            }
            await disposeTaskService.transition(taskId, TaskStatus.running, trigger: 'test-worker');
            if (conflict == 'version-conflict') {
              throw Exception('simulated version conflict');
            }
          }
          if (promotionAttempts == 2 &&
              conflict == 'retry-running-version-conflict' &&
              newStatus == TaskStatus.running) {
            await disposeTaskService.transition(taskId, TaskStatus.running, trigger: 'test-worker');
            throw Exception('simulated retry version conflict');
          }
          if (promotionAttempts == 2 &&
              conflict == 'retry-queued-version-conflict' &&
              newStatus == TaskStatus.running) {
            throw Exception('simulated retry queued version conflict');
          }
        },
      );
      final disposeMessages = MessageService(baseDir: p.join(tempDir.path, 'dispose-$conflict-sessions'));
      final disposeKv = KvService(filePath: p.join(tempDir.path, 'dispose-$conflict-kv.json'));
      final disposeWorkflowService = WorkflowService(
        repository: SqliteWorkflowRunRepository(disposeDb),
        taskService: disposeRecordingTasks,
        messageService: disposeMessages,
        persistencePorts: WorkflowPersistencePorts(
          taskRepository: disposeTaskRepository,
          agentExecutionRepository: disposeAgentExecutions,
          workflowStepExecutionRepository: disposeStepExecutions,
          executionRepositoryTransactor: disposeTransactor,
        ),
        eventBus: disposeEventBus,
        kvService: disposeKv,
        dataDir: tempDir.path,
      );
      addTearDown(disposeWorkflowService.dispose);
      addTearDown(disposeTaskService.dispose);
      addTearDown(disposeMessages.dispose);
      addTearDown(disposeKv.dispose);
      addTearDown(taskEventSub.cancel);
      addTearDown(disposeEventBus.dispose);
      addTearDown(disposeDb.close);

      final disposeRun = await disposeWorkflowService.start(makeDefinition(), {});
      Future<Task?> queuedTaskForRun() async {
        for (var attempt = 0; attempt < 200; attempt += 1) {
          final tasks = await disposeTaskService.listByWorkflowRunIds([disposeRun.id]);
          for (final task in tasks) {
            if (task.status == TaskStatus.queued) {
              return task;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return null;
      }

      final task = await queuedTaskForRun();
      expect(task, isNotNull, reason: conflict);

      await disposeWorkflowService.dispose();

      expect(
        promotionAttempts,
        conflict == 'retry-queued-version-conflict'
            ? 3
            : conflict == 'stored-queued-version-conflict' || conflict == 'retry-running-version-conflict'
            ? 2
            : 1,
        reason: conflict,
      );
      expect((await disposeTaskService.get(task!.id))?.status, TaskStatus.cancelled, reason: conflict);
      final taskStatuses = [
        for (final event in taskEvents)
          if (event.taskId == task.id) event.newStatus,
      ];
      final runningIndex = taskStatuses.indexOf(TaskStatus.running);
      final cancelledIndex = taskStatuses.indexOf(TaskStatus.cancelled);
      expect(runningIndex, isNonNegative, reason: conflict);
      expect(cancelledIndex, isNonNegative, reason: conflict);
      expect(runningIndex, lessThan(cancelledIndex), reason: conflict);
    }
  });

  test('dispose() bounds queued promotion and falls back to direct cancellation under persistent conflicts', () async {
    final disposeDb = openTaskDbInMemory();
    final disposeEventBus = EventBus();
    final disposeTaskRepository = SqliteTaskRepository(disposeDb);
    final disposeAgentExecutions = SqliteAgentExecutionRepository(disposeDb, eventBus: disposeEventBus);
    final disposeStepExecutions = SqliteWorkflowStepExecutionRepository(disposeDb);
    final disposeTransactor = SqliteExecutionRepositoryTransactor(disposeDb);
    final disposeTaskService = TaskService(
      disposeTaskRepository,
      agentExecutionRepository: disposeAgentExecutions,
      executionTransactor: disposeTransactor,
      eventBus: disposeEventBus,
    );
    var promotionAttempts = 0;
    final disposeRecordingTasks = _RecordingWorkflowTaskService(
      disposeTaskService,
      beforeTransition: (taskId, newStatus) async {
        // Promotion (queued -> running) persistently conflicts; the direct
        // queued -> cancelled fallback is allowed to succeed.
        if (newStatus == TaskStatus.running) {
          promotionAttempts += 1;
          throw Exception('persistent queued promotion conflict');
        }
      },
    );
    final disposeMessages = MessageService(baseDir: p.join(tempDir.path, 'dispose-persistent-sessions'));
    final disposeKv = KvService(filePath: p.join(tempDir.path, 'dispose-persistent-kv.json'));
    final disposeWorkflowService = WorkflowService(
      repository: SqliteWorkflowRunRepository(disposeDb),
      taskService: disposeRecordingTasks,
      messageService: disposeMessages,
      persistencePorts: WorkflowPersistencePorts(
        taskRepository: disposeTaskRepository,
        agentExecutionRepository: disposeAgentExecutions,
        workflowStepExecutionRepository: disposeStepExecutions,
        executionRepositoryTransactor: disposeTransactor,
      ),
      eventBus: disposeEventBus,
      kvService: disposeKv,
      dataDir: tempDir.path,
    );
    addTearDown(disposeWorkflowService.dispose);
    addTearDown(disposeTaskService.dispose);
    addTearDown(disposeMessages.dispose);
    addTearDown(disposeKv.dispose);
    addTearDown(disposeEventBus.dispose);
    addTearDown(disposeDb.close);

    final disposeRun = await disposeWorkflowService.start(makeDefinition(), {});
    Future<Task?> queuedTaskForRun() async {
      for (var attempt = 0; attempt < 200; attempt += 1) {
        final tasks = await disposeTaskService.listByWorkflowRunIds([disposeRun.id]);
        for (final task in tasks) {
          if (task.status == TaskStatus.queued) {
            return task;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return null;
    }

    final task = await queuedTaskForRun();
    expect(task, isNotNull);

    // Must return rather than spinning on the persistent conflict.
    await disposeWorkflowService.dispose();

    // Promotion is bounded, then dispose falls back to a direct cancellation so
    // the executor's task-wait completes and the drain finishes.
    expect(promotionAttempts, WorkflowService.maxDisposePromotionAttempts);
    expect((await disposeTaskService.get(task!.id))?.status, TaskStatus.cancelled);
  });

  test('cancel() is idempotent on already-terminal run', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();
    final run = await workflowService.start(definition, {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Run may be completed already.
    await workflowService.cancel(run.id);
    // Second cancel should not throw.
    await workflowService.cancel(run.id);
  });

  test('get() returns null for unknown run', () async {
    final result = await workflowService.get('nonexistent-id');
    expect(result, isNull);
  });

  test('list() returns all runs', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();

    await workflowService.start(definition, {});
    await workflowService.start(definition, {});

    final runs = await workflowService.list();
    expect(runs.length, greaterThanOrEqualTo(2));
  });

  test('list() filters by status', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    await workflowService.pause(run.id);

    final pausedRuns = await workflowService.list(status: WorkflowRunStatus.paused);
    expect(pausedRuns.any((r) => r.id == run.id), isTrue);

    final runningRuns = await workflowService.list(status: WorkflowRunStatus.running);
    expect(runningRuns.any((r) => r.id == run.id), isFalse);
  });

  test('recoverIncompleteRuns() resumes running runs', () async {
    // Seed a "running" run directly in the repository.
    final definition = makeDefinition();
    await insertRun(
      id: 'recover-run-1',
      status: WorkflowRunStatus.running,
      currentStepIndex: 0,
      definition: definition,
    );

    autoCompleteNewTasks();

    await workflowService.recoverIncompleteRuns();

    // Wait for recovery to complete.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final recovered = await workflowService.get('recover-run-1');
    // Should have been recovered and completed (or transitioned out of initial state).
    expect(
      recovered?.status,
      anyOf(equals(WorkflowRunStatus.completed), equals(WorkflowRunStatus.paused), equals(WorkflowRunStatus.running)),
    );
  });

  test('recoverIncompleteRuns() preserves active loop step id when resuming mid-loop', () async {
    final definition = WorkflowDefinition(
      name: 'loop-recovery',
      description: 'Loop recovery',
      steps: [
        const WorkflowStep(id: 'loopA', name: 'Loop A', prompts: ['Do A']),
        const WorkflowStep(id: 'loopB', name: 'Loop B', prompts: ['Do B']),
      ],
      loops: const [
        WorkflowLoop(id: 'loop1', steps: ['loopA', 'loopB'], maxIterations: 3, exitGate: 'loopB.status == accepted'),
      ],
    );

    await insertRun(
      id: 'recover-loop-step',
      status: WorkflowRunStatus.running,
      currentStepIndex: 0,
      definition: definition,
      contextJson: {
        '_loop.current.id': 'loop1',
        '_loop.current.iteration': 1,
        '_loop.current.stepId': 'loopB',
        'data': <String, dynamic>{'loopA.status': 'accepted', 'loopA.tokenCount': 50},
        'variables': <String, dynamic>{},
        'loopA.status': 'accepted',
        'loopA.tokenCount': 50,
      },
    );

    final createdTaskTitles = <String>[];
    autoCompleteNewTasks(createdTaskTitles);

    await workflowService.recoverIncompleteRuns();
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(createdTaskTitles, hasLength(1));
    expect(createdTaskTitles.first, contains('Loop B'));

    final recovered = await workflowService.get('recover-loop-step');
    expect(recovered?.status, equals(WorkflowRunStatus.completed));
  });

  test('recoverIncompleteRuns() resumes unfinished map iterations without replaying settled items', () async {
    final definition = WorkflowDefinition(
      name: 'map-recovery',
      description: 'Map recovery',
      steps: const [
        WorkflowStep(
          id: 'map',
          name: 'Map',
          prompts: ['Process {{map.item}}'],
          mapOver: 'items',
          maxParallel: 1,
          outputs: {'mapped': OutputConfig()},
        ),
      ],
    );

    await insertRun(
      id: 'recover-map-step',
      status: WorkflowRunStatus.running,
      currentStepIndex: 0,
      definition: definition,
      executionCursor: WorkflowExecutionCursor.map(
        stepId: 'map',
        stepIndex: 0,
        totalItems: 3,
        completedIndices: const [0, 1],
        resultSlots: const ['done-a', 'done-b', null],
      ),
      contextJson: {
        'data': {
          'items': ['a', 'b', 'c'],
          'map[0].tokenCount': 5,
          'map[1].tokenCount': 5,
        },
        'variables': <String, dynamic>{},
      },
    );

    final createdTaskTitles = <String>[];
    autoCompleteNewTasks(createdTaskTitles);

    await workflowService.recoverIncompleteRuns();
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(createdTaskTitles, hasLength(1));
    expect(createdTaskTitles.single, contains('(3/3)'));

    final recovered = await workflowService.get('recover-map-step');
    expect(recovered?.status, equals(WorkflowRunStatus.completed));
    expect(((recovered?.contextJson['data'] as Map?)?['mapped'] as List?)?.length, equals(3));
  });

  test('recoverIncompleteRuns() skips paused runs', () async {
    final definition = makeDefinition();
    await insertRun(id: 'paused-run-1', status: WorkflowRunStatus.paused, definition: definition);

    await workflowService.recoverIncompleteRuns();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Paused run should remain paused — not auto-resumed.
    final stored = await workflowService.get('paused-run-1');
    expect(stored?.status, equals(WorkflowRunStatus.paused));
  });

  test('WorkflowRunStatusChangedEvent fired on start, pause, cancel', () async {
    final events = <WorkflowRunStatusChangedEvent>[];
    eventBus.on<WorkflowRunStatusChangedEvent>().listen(events.add);

    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    await workflowService.pause(run.id);
    await workflowService.cancel(run.id);

    final statuses = events.map((e) => e.newStatus).toList();
    expect(statuses, containsAll([WorkflowRunStatus.running, WorkflowRunStatus.paused, WorkflowRunStatus.cancelled]));
  });

  group('approval resume/cancel semantics', () {
    /// Inserts a paused run with approval metadata as if the executor had paused it.
    Future<WorkflowRun> insertApprovalPausedRun({
      String runId = 'run-approval',
      String stepId = 'gate',
      int nextStepIndex = 1,
      DateTime? timeoutDeadline,
      Map<String, String> variables = const {},
      WorkflowGitStrategy? gitStrategy,
      WorkflowApprovalPolicy? approvals,
    }) async {
      final definition = makeDefinition(
        gitStrategy: gitStrategy,
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );
      final now = DateTime.now();
      return insertRun(
        id: runId,
        status: WorkflowRunStatus.paused,
        currentStepIndex: nextStepIndex,
        definition: definition,
        variablesJson: variables,
        contextJson: {
          'data': <String, dynamic>{
            '$stepId.status': 'pending',
            '$stepId.approval.status': 'pending',
            '$stepId.approval.message': 'Approve?',
            '$stepId.approval.requested_at': now.toIso8601String(),
            '$stepId.tokenCount': 0,
            if (approvals != null) '_workflow.approvals': approvals.yamlValue,
            if (timeoutDeadline != null) '$stepId.approval.timeout_deadline': timeoutDeadline.toIso8601String(),
          },
          'variables': Map<String, dynamic>.from(variables),
          '$stepId.status': 'pending',
          '$stepId.approval.status': 'pending',
          '$stepId.approval.message': 'Approve?',
          '$stepId.approval.requested_at': now.toIso8601String(),
          '$stepId.tokenCount': 0,
          if (timeoutDeadline != null) '$stepId.approval.timeout_deadline': timeoutDeadline.toIso8601String(),
          if (approvals != null) '_workflow.approvals': approvals.yamlValue,
          '_approval.pending.stepId': stepId,
          '_approval.pending.stepIndex': nextStepIndex - 1,
        },
        writeContextFile: true,
      );
    }

    test('resume() on approval-paused run records approved status and fires WorkflowApprovalResolvedEvent', () async {
      final resolvedEvents = <WorkflowApprovalResolvedEvent>[];
      eventBus.on<WorkflowApprovalResolvedEvent>().listen(resolvedEvents.add);

      await insertApprovalPausedRun();
      autoCompleteNewTasks();

      await workflowService.resume('run-approval');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(resolvedEvents, hasLength(1));
      expect(resolvedEvents.first.runId, equals('run-approval'));
      expect(resolvedEvents.first.stepId, equals('gate'));
      expect(resolvedEvents.first.approved, isTrue);
      expect(resolvedEvents.first.feedback, isNull);

      final updated = await workflowService.get('run-approval');
      final data = updated?.contextJson['data'] as Map<String, dynamic>?;
      expect(data?['gate.status'], equals('accepted'));
      expect(data?['gate.approval.status'], equals('approved'));
    });

    test('resume() preserves approvals policy for later needsInput auto-resolution', () async {
      await insertApprovalPausedRun(approvals: WorkflowApprovalPolicy.autoOnStall);

      final resolvedEvents = <WorkflowApprovalResolvedEvent>[];
      eventBus.on<WorkflowApprovalResolvedEvent>().listen(resolvedEvents.add);

      final sessionService = SessionService(baseDir: p.join(tempDir.path, 'sessions'));
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        final session = await sessionService.createSession(type: SessionType.task);
        await taskService.updateFields(task.id, sessionId: session.id);
        await harness.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content:
              'Blocked pending human decision.\n'
              '<step-outcome>{"outcome":"needsInput","reason":"later stall"}</step-outcome>',
        );
        await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
        await taskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
        await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
      });
      addTearDown(sub.cancel);

      await workflowService.resume('run-approval');
      await harness.waitForRunStatus('run-approval', WorkflowRunStatus.completed);

      final updated = await workflowService.get('run-approval');
      final data = updated?.contextJson['data'] as Map<String, dynamic>;
      final audit = data['_approval.auto_resolved.step2'] as Map<String, dynamic>;
      expect(updated?.contextJson['_workflow.approvals'], 'auto-on-stall');
      expect(audit['policy'], 'auto-on-stall');
      expect(audit['reason'], 'later stall');
      expect(audit['source'], 'needsInput');

      // OC05: the dispatcher needsInput auto-resolution must also fire the
      // approval/status event (not just write the audit record), so SSE/UI
      // observers see the auto-resolved gate.
      final step2Event = resolvedEvents.where((e) => e.stepId == 'step2');
      expect(step2Event, hasLength(1), reason: 'needsInput auto-resolve must fire WorkflowApprovalResolvedEvent');
      expect(step2Event.first.approved, isTrue);
      expect(step2Event.first.feedback, 'later stall');
    });

    test('resume() clears _approval.pending.* tracking keys from contextJson', () async {
      await insertApprovalPausedRun();
      autoCompleteNewTasks();

      await workflowService.resume('run-approval');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Re-read from DB — pending keys should be gone.
      final updated = await workflowService.get('run-approval');
      expect(updated?.contextJson.containsKey('_approval.pending.stepId'), isFalse);
      expect(updated?.contextJson.containsKey('_approval.pending.stepIndex'), isFalse);
    });

    test('cancel() on approval-paused run records rejected status and fires WorkflowApprovalResolvedEvent', () async {
      final resolvedEvents = <WorkflowApprovalResolvedEvent>[];
      eventBus.on<WorkflowApprovalResolvedEvent>().listen(resolvedEvents.add);

      await insertApprovalPausedRun();

      await workflowService.cancel('run-approval');

      expect(resolvedEvents, hasLength(1));
      expect(resolvedEvents.first.approved, isFalse);
      expect(resolvedEvents.first.feedback, isNull);

      final updated = await workflowService.get('run-approval');
      expect(updated?.contextJson['gate.approval.status'], equals('rejected'));
      expect(updated?.contextJson['gate.status'], equals('rejected'));
    });

    test('cancel() with feedback stores feedback in contextJson and event', () async {
      final resolvedEvents = <WorkflowApprovalResolvedEvent>[];
      eventBus.on<WorkflowApprovalResolvedEvent>().listen(resolvedEvents.add);

      await insertApprovalPausedRun();

      await workflowService.cancel('run-approval', feedback: 'Not ready yet');

      expect(resolvedEvents.first.feedback, equals('Not ready yet'));

      final updated = await workflowService.get('run-approval');
      expect(updated?.contextJson['gate.approval.feedback'], equals('Not ready yet'));
      expect(updated?.contextJson['gate.approval.status'], equals('rejected'));
      expect(updated?.contextJson['gate.status'], equals('rejected'));
    });

    test('resume() persists resolved approval status to context.json', () async {
      await insertApprovalPausedRun();
      autoCompleteNewTasks();

      await workflowService.resume('run-approval');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final file = File(p.join(tempDir.path, 'workflows', 'runs', 'run-approval', 'context.json'));
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>;
      expect(data['gate.status'], equals('accepted'));
      expect(data['gate.approval.status'], equals('approved'));
    });

    test('recoverIncompleteRuns() auto-cancels expired approval deadlines after restart', () async {
      await insertApprovalPausedRun(
        runId: 'run-expired-approval',
        timeoutDeadline: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      await workflowService.recoverIncompleteRuns();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final updated = await workflowService.get('run-expired-approval');
      expect(updated?.status, equals(WorkflowRunStatus.cancelled));
      expect(updated?.contextJson['gate.approval.status'], equals('timed_out'));
      expect(updated?.contextJson['gate.approval.cancel_reason'], equals('timeout'));
    });

    test('recoverIncompleteRuns() cleans workflow git after expired approval deadline', () async {
      final cleanupStatuses = <({String runId, String projectId, String status, bool preserveWorktrees})>[];
      workflowService = lifecycleOnlyService(
        turnAdapter: standardTurnAdapter(
          turnId: 'turn-id',
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                cleanupStatuses.add((
                  runId: runId,
                  projectId: projectId,
                  status: status,
                  preserveWorktrees: preserveWorktrees,
                ));
              },
        ),
      );
      await insertApprovalPausedRun(
        runId: 'run-expired-cleanup',
        timeoutDeadline: DateTime.now().subtract(const Duration(seconds: 1)),
        variables: const {'PROJECT': 'my-app'},
        gitStrategy: const WorkflowGitStrategy(cleanup: true),
      );

      await workflowService.recoverIncompleteRuns();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(cleanupStatuses, hasLength(1));
      expect(cleanupStatuses.single, (
        runId: 'run-expired-cleanup',
        projectId: 'my-app',
        status: 'cancelled',
        preserveWorktrees: false,
      ));
    });

    test('cancel() on non-approval run ignores feedback and does not fire WorkflowApprovalResolvedEvent', () async {
      final resolvedEvents = <WorkflowApprovalResolvedEvent>[];
      eventBus.on<WorkflowApprovalResolvedEvent>().listen(resolvedEvents.add);

      final definition = makeDefinition();
      final run = await workflowService.start(definition, {});
      await workflowService.pause(run.id);

      await workflowService.cancel(run.id, feedback: 'irrelevant');

      expect(resolvedEvents, isEmpty);
      final updated = await workflowService.get(run.id);
      expect(updated?.status, equals(WorkflowRunStatus.cancelled));
    });
  });

  group('retry()', () {
    Future<WorkflowRun> insertFailedRun({
      String runId = 'run-failed',
      String failingStepId = 'step1',
      int currentStepIndex = 0,
      WorkflowExecutionCursor? executionCursor,
      Map<String, dynamic> contextJson = const {},
      Map<String, dynamic>? diskContextJson,
    }) {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );
      final context = {
        '$failingStepId.status': 'failed',
        'step.$failingStepId.outcome': 'failed',
        'step.$failingStepId.outcome.reason': 'boom',
        ...contextJson,
      };
      return insertRun(
        id: runId,
        status: WorkflowRunStatus.failed,
        errorMessage: 'boom',
        currentStepIndex: currentStepIndex,
        definition: definition,
        contextJson: context,
        executionCursor: executionCursor,
        writeContextFile: diskContextJson == null,
      ).then((run) {
        if (diskContextJson != null) writeContextSnapshot(run.id, diskContextJson);
        return run;
      });
    }

    test('throws StateError when run is not in failed status', () async {
      final definition = makeDefinition();
      final run = await workflowService.start(definition, {});
      await workflowService.pause(run.id);
      expect(() => workflowService.retry(run.id), throwsA(isA<StateError>()));
    });

    test('transitions failed → running and fires status event', () async {
      final statusEvents = <WorkflowRunStatusChangedEvent>[];
      eventBus.on<WorkflowRunStatusChangedEvent>().listen(statusEvents.add);

      final run = await insertFailedRun();
      autoCompleteNewTasks();

      final retried = await workflowService.retry(run.id);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(retried.status, equals(WorkflowRunStatus.running));
      expect(
        statusEvents.any((e) => e.oldStatus == WorkflowRunStatus.failed && e.newStatus == WorkflowRunStatus.running),
        isTrue,
      );
    });

    test('clears failing step status/outcome context keys', () async {
      final run = await insertFailedRun();
      autoCompleteNewTasks();

      await workflowService.retry(run.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final updated = await workflowService.get(run.id);
      expect(updated?.contextJson.containsKey('step1.status'), isFalse);
      expect(updated?.contextJson.containsKey('step.step1.outcome'), isFalse);
      expect(updated?.contextJson.containsKey('step.step1.outcome.reason'), isFalse);
    });

    test('retry with execution cursor prefers DB context over divergent disk snapshot', () async {
      final run = await insertFailedRun(
        executionCursor: WorkflowExecutionCursor.foreach(
          stepId: 'step1',
          stepIndex: 0,
          totalItems: 2,
          completedIndices: [0],
        ),
        contextJson: {
          'story_results': ['db-completed'],
        },
        diskContextJson: {
          'step1.status': 'failed',
          'step.step1.outcome': 'failed',
          'step.step1.outcome.reason': 'boom',
          'story_results': ['stale-disk'],
        },
      );

      final retried = await workflowService.retry(run.id);

      expect(retried.contextJson['story_results'], ['db-completed']);
      expect(retried.contextJson['story_results'], isNot(['stale-disk']));
    });
  });

  group('operator lifecycle action precedence', () {
    final approvalContext = <String, dynamic>{
      '_approval.pending.stepId': 'gate',
      '_approval.pending.stepIndex': 0,
      'gate.approval.status': 'pending',
      'data': <String, dynamic>{},
      'variables': <String, dynamic>{},
    };
    final illegalCombos =
        <
          ({
            String name,
            WorkflowRunStatus status,
            Future<void> Function(WorkflowService svc, String runId) action,
            bool noOp,
            Map<String, dynamic>? contextJson,
            int currentStepIndex,
          })
        >[
          (
            name: 'retry() on awaitingApproval run is rejected with StateError',
            status: WorkflowRunStatus.awaitingApproval,
            action: (svc, id) => svc.retry(id),
            noOp: false,
            contextJson: approvalContext,
            currentStepIndex: 1,
          ),
          (
            name: 'retry() on running run is rejected with StateError',
            status: WorkflowRunStatus.running,
            action: (svc, id) => svc.retry(id),
            noOp: false,
            contextJson: null,
            currentStepIndex: 0,
          ),
          (
            name: 'resume() on failed run is rejected with StateError',
            status: WorkflowRunStatus.failed,
            action: (svc, id) => svc.resume(id),
            noOp: false,
            contextJson: null,
            currentStepIndex: 0,
          ),
          (
            name: 'cancel() is a no-op on completed run',
            status: WorkflowRunStatus.completed,
            action: (svc, id) => svc.cancel(id),
            noOp: true,
            contextJson: null,
            currentStepIndex: 0,
          ),
          (
            name: 'cancel() is a no-op on cancelled run',
            status: WorkflowRunStatus.cancelled,
            action: (svc, id) => svc.cancel(id),
            noOp: true,
            contextJson: null,
            currentStepIndex: 0,
          ),
          (
            name: 'retry() on completed run is rejected with StateError',
            status: WorkflowRunStatus.completed,
            action: (svc, id) => svc.retry(id),
            noOp: false,
            contextJson: null,
            currentStepIndex: 0,
          ),
          (
            name: 'retry() on cancelled run is rejected with StateError',
            status: WorkflowRunStatus.cancelled,
            action: (svc, id) => svc.retry(id),
            noOp: false,
            contextJson: null,
            currentStepIndex: 0,
          ),
          (
            name: 'resume() on completed run is rejected with StateError',
            status: WorkflowRunStatus.completed,
            action: (svc, id) => svc.resume(id),
            noOp: false,
            contextJson: null,
            currentStepIndex: 0,
          ),
          (
            name: 'resume() on cancelled run is rejected with StateError',
            status: WorkflowRunStatus.cancelled,
            action: (svc, id) => svc.resume(id),
            noOp: false,
            contextJson: null,
            currentStepIndex: 0,
          ),
        ];

    for (final row in illegalCombos) {
      test(row.name, () async {
        final runId = 'run-illegal-${illegalCombos.indexOf(row)}';
        await insertRun(
          id: runId,
          status: row.status,
          currentStepIndex: row.currentStepIndex,
          contextJson: row.contextJson ?? const {},
        );

        if (row.noOp) {
          await row.action(workflowService, runId);
          final stored = await workflowService.get(runId);
          expect(stored?.status, equals(row.status));
        } else {
          await expectLater(row.action(workflowService, runId), throwsA(isA<StateError>()));
        }
      });
    }

    test('resume() accepts awaitingApproval run, clears approval-tracking keys, and flips status to running', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          const WorkflowStep(id: 'step2', name: 'Step 2', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
        ],
      );
      await insertRun(
        id: 'run-awaiting-resume',
        status: WorkflowRunStatus.awaitingApproval,
        currentStepIndex: 1,
        definition: definition,
        contextJson: {
          '_approval.pending.stepId': 'gate',
          '_approval.pending.stepIndex': 0,
          'gate.approval.status': 'pending',
          'data': <String, dynamic>{},
          'variables': <String, dynamic>{},
        },
        writeContextFile: true,
      );
      autoCompleteNewTasks();

      final resumed = await workflowService.resume('run-awaiting-resume');
      expect(resumed.status, equals(WorkflowRunStatus.running));

      expect(resumed.contextJson.containsKey('_approval.pending.stepId'), isFalse);
      expect(resumed.contextJson.containsKey('_approval.pending.stepIndex'), isFalse);
    });

    test('retry() on paused run is rejected with StateError', () async {
      final definition = makeDefinition();
      final run = await workflowService.start(definition, {});
      await workflowService.pause(run.id);
      await expectLater(workflowService.retry(run.id), throwsA(isA<StateError>()));
    });
  });

  group('restart/retry idempotency after side effects', () {
    test('retry() starts from persisted execution cursor — not from step 0', () async {
      final definition = WorkflowDefinition(
        name: 'map-retry',
        description: 'map retry idempotency',
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['impl {{map.item}}'],
            mapOver: 'items',
            maxParallel: 1,
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'update-state', name: 'Update State', prompts: ['update']),
        ],
      );
      final cursor = WorkflowExecutionCursor.map(
        stepId: 'implement',
        stepIndex: 0,
        totalItems: 3,
        completedIndices: const [0, 1],
        resultSlots: const ['done-a', 'done-b', null],
      );
      await insertRun(
        id: 'run-map-retry',
        status: WorkflowRunStatus.failed,
        errorMessage: 'item 2 failed',
        definition: definition,
        executionCursor: cursor,
        contextJson: {
          'data': <String, dynamic>{
            'items': ['a', 'b', 'c'],
            'implement[0].tokenCount': 10,
            'implement[1].tokenCount': 10,
          },
          'variables': <String, dynamic>{},
        },
      );

      final allDispatchedTitles = <String>[];
      autoCompleteNewTasks(allDispatchedTitles);

      final terminalCompleter = Completer<WorkflowRunStatus>();
      final statusSub = eventBus
          .on<WorkflowRunStatusChangedEvent>()
          .where((e) => e.runId == 'run-map-retry' && e.newStatus.terminal)
          .listen((e) {
            if (!terminalCompleter.isCompleted) terminalCompleter.complete(e.newStatus);
          });

      await workflowService.retry('run-map-retry');
      final terminalStatus = await terminalCompleter.future.timeout(const Duration(seconds: 5));
      await statusSub.cancel();

      final mapDispatched = allDispatchedTitles.where((t) => t.contains('Implement')).toList();
      expect(
        mapDispatched.any((t) => t.contains('(1/3)') || t.contains('(2/3)')),
        isFalse,
        reason: 'Completed map items (0,1) must not be replayed on retry',
      );
      expect(mapDispatched, hasLength(1), reason: 'only the pending cursor item should dispatch');
      expect(mapDispatched.single, contains('(3/3)'));
      expect(terminalStatus, equals(WorkflowRunStatus.completed));
    });
  });

  group('approval/needsInput hold state preservation', () {
    test('resume() after awaitingApproval preserves worktree bindings from before hold', () async {
      final hydrated = <WorkflowWorktreeBinding>[];
      workflowService = lifecycleOnlyService(
        gitContext: WorkflowGitContext(
          gitPort: FakeGitGateway(),
          hydrateBinding: (binding) {
            hydrated.add(binding);
          },
        ),
      );
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          const WorkflowStep(id: 'step2', name: 'Step 2', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
        ],
      );
      await insertRun(
        id: 'run-hold-worktree',
        status: WorkflowRunStatus.awaitingApproval,
        currentStepIndex: 1,
        definition: definition,
        contextJson: {
          '_approval.pending.stepId': 'gate',
          '_approval.pending.stepIndex': 0,
          'gate.approval.status': 'pending',
          'data': <String, dynamic>{},
          'variables': <String, dynamic>{},
        },
        workflowWorktree: const WorkflowWorktreeBinding(
          key: 'run-hold-worktree',
          path: '/tmp/worktrees/wf-hold',
          branch: 'dartclaw/workflow/hold/integration',
          workflowRunId: 'run-hold-worktree',
        ),
        writeContextFile: true,
      );
      autoCompleteNewTasks();

      await workflowService.resume('run-hold-worktree');

      expect(hydrated, hasLength(1));
      expect(hydrated.single.key, 'run-hold-worktree');
      expect(hydrated.single.path, '/tmp/worktrees/wf-hold');
    });

    test('awaitingApproval run preserves run context and audit state through hold', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'impl', name: 'Impl', prompts: ['Implement']),
          const WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval, prompts: ['Approve?']),
          const WorkflowStep(id: 'publish', name: 'Publish', prompts: ['Publish']),
        ],
      );
      await insertRun(
        id: 'run-hold-context',
        status: WorkflowRunStatus.awaitingApproval,
        currentStepIndex: 2,
        definition: definition,
        contextJson: {
          '_approval.pending.stepId': 'gate',
          '_approval.pending.stepIndex': 1,
          'gate.approval.status': 'pending',
          'impl.status': 'accepted',
          'step.impl.outcome': 'succeeded',
          'impl.tokenCount': 150,
          'data': <String, dynamic>{
            'impl.status': 'accepted',
            'step.impl.outcome': 'succeeded',
            'impl.tokenCount': 150,
          },
          'variables': <String, dynamic>{},
        },
      );

      final stored = await workflowService.get('run-hold-context');
      expect(stored?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(stored?.contextJson['step.impl.outcome'], equals('succeeded'));
      expect(stored?.contextJson['impl.tokenCount'], equals(150));
      expect(stored?.contextJson['_approval.pending.stepId'], equals('gate'));
    });
  });

  group('concurrent checkout contention rule', () {
    test('RepoLock serializes concurrent operations on the same key', () async {
      final lock = RepoLock();
      final executionOrder = <String>[];
      final completerA = Completer<void>();

      final futureA = lock.acquire('/tmp/repo', () async {
        executionOrder.add('A-start');
        await completerA.future;
        executionOrder.add('A-end');
      });

      final futureB = lock.acquire('/tmp/repo', () async {
        executionOrder.add('B-start');
        executionOrder.add('B-end');
      });

      await Future<void>.delayed(Duration.zero);
      expect(executionOrder, equals(['A-start']), reason: 'B must not start while A holds the lock');

      completerA.complete();
      await Future.wait([futureA, futureB]);

      expect(executionOrder, equals(['A-start', 'A-end', 'B-start', 'B-end']));
    });

    test('RepoLock allows concurrent operations on different keys', () async {
      final lock = RepoLock();
      final executionOrder = <String>[];
      final completerA = Completer<void>();

      final futureA = lock.acquire('/tmp/repo-a', () async {
        executionOrder.add('A-start');
        await completerA.future;
        executionOrder.add('A-end');
      });

      final futureB = lock.acquire('/tmp/repo-b', () async {
        executionOrder.add('B-start');
        executionOrder.add('B-end');
      });

      await futureB;

      expect(executionOrder, equals(['A-start', 'B-start', 'B-end']));

      completerA.complete();
      await futureA;
      expect(executionOrder, equals(['A-start', 'B-start', 'B-end', 'A-end']));
    });
  });

  group('local human-edit detection boundary', () {
    test('WorkflowService start() propagates preflight dirty-path rejection', () async {
      workflowService = lifecycleOnlyService(
        turnAdapter: standardTurnAdapter(
          turnId: 'turn-id',
          resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
            // Simulate dirty-path preflight rejection (as WorkflowLocalPathPreflight does).
            throw ArgumentError(
              'Working tree has uncommitted changes. Commit or stash changes before starting a workflow.',
            );
          },
        ),
      );
      final definition = makeDefinition(variables: const {'PROJECT': WorkflowVariable(required: false)});

      await expectLater(
        workflowService.start(definition, const {'PROJECT': '_local'}),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('uncommitted changes'))),
      );
      // No run must have been created.
      expect(await workflowService.list(), isEmpty);
    });
  });

  group('recovery boundary', () {
    test('recoverIncompleteRuns() skips run with corrupt definitionJson without crashing', () async {
      final now = DateTime.now();
      final badRun = WorkflowRun(
        id: 'corrupt-json-run',
        definitionName: 'bad-workflow',
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        definitionJson: {'__corrupt': true, 'not_a_real_def': 42},
      );
      await repository.insert(badRun);

      // Should complete without throwing — skips the corrupt run gracefully.
      await expectLater(workflowService.recoverIncompleteRuns(), completes);

      // The corrupt run must remain in 'running' state (not attempted).
      final stored = await workflowService.get('corrupt-json-run');
      expect(stored?.status, equals(WorkflowRunStatus.running));
    });

    test('recoverIncompleteRuns() skips completed and cancelled runs', () async {
      final now = DateTime.now();
      final definition = makeDefinition();
      for (final status in [WorkflowRunStatus.completed, WorkflowRunStatus.cancelled]) {
        final run = WorkflowRun(
          id: 'terminal-${status.name}',
          definitionName: 'test-workflow',
          status: status,
          startedAt: now,
          updatedAt: now,
          definitionJson: definition.toJson(),
        );
        await repository.insert(run);
      }

      // No exception, no spurious executor spawns for terminal runs.
      await expectLater(workflowService.recoverIncompleteRuns(), completes);

      for (final status in [WorkflowRunStatus.completed, WorkflowRunStatus.cancelled]) {
        final stored = await workflowService.get('terminal-${status.name}');
        expect(stored?.status, equals(status));
      }
    });
  });
}

final class _RecordingWorkflowTaskService implements WorkflowTaskService {
  _RecordingWorkflowTaskService(
    this._delegate, {
    Future<void> Function()? beforeListByWorkflowRunIds,
    Future<void> Function(String taskId, TaskStatus newStatus)? beforeTransition,
  }) : _beforeListByWorkflowRunIds = beforeListByWorkflowRunIds,
       _beforeTransition = beforeTransition;

  final WorkflowTaskService _delegate;
  final Future<void> Function()? _beforeListByWorkflowRunIds;
  final Future<void> Function(String taskId, TaskStatus newStatus)? _beforeTransition;
  int listCallCount = 0;
  final listByWorkflowRunIdsCalls = <List<String>>[];

  @override
  Future<Task?> get(String id) => _delegate.get(id);

  @override
  Future<Task> create({
    required String id,
    required String title,
    required String description,
    required TaskType type,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    String? createdBy,
    String? provider,
    String? model,
    String? sessionId,
    String? agentExecutionId,
    String? projectId,
    int? maxTokens,
    String? workflowRunId,
    int? stepIndex,
    int maxRetries = 0,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
    String trigger = 'system',
  }) => _delegate.create(
    id: id,
    title: title,
    description: description,
    type: type,
    autoStart: autoStart,
    goalId: goalId,
    acceptanceCriteria: acceptanceCriteria,
    createdBy: createdBy,
    provider: provider,
    model: model,
    sessionId: sessionId,
    agentExecutionId: agentExecutionId,
    projectId: projectId,
    maxTokens: maxTokens,
    workflowRunId: workflowRunId,
    stepIndex: stepIndex,
    maxRetries: maxRetries,
    configJson: configJson,
    now: now,
    trigger: trigger,
  );

  @override
  Future<Task> transition(
    String taskId,
    TaskStatus newStatus, {
    DateTime? now,
    Map<String, dynamic>? configJson,
    String trigger = 'system',
  }) async {
    await _beforeTransition?.call(taskId, newStatus);
    return _delegate.transition(taskId, newStatus, now: now, configJson: configJson, trigger: trigger);
  }

  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) {
    listCallCount += 1;
    return _delegate.list(status: status, type: type);
  }

  @override
  Future<List<Task>> listByWorkflowRunIds(Iterable<String> runIds) async {
    if (runIds is! List<String> || runIds.isNotEmpty) {
      await _beforeListByWorkflowRunIds?.call();
    }
    listByWorkflowRunIdsCalls.add(runIds.toList(growable: false));
    return _delegate.listByWorkflowRunIds(runIds);
  }

  @override
  Future<List<TaskArtifact>> listArtifacts(String taskId) => _delegate.listArtifacts(taskId);
}
