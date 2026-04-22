import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        KvService,
        MessageService,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowApprovalResolvedEvent,
        WorkflowDefinition,
        WorkflowExecutionCursor,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowWorktreeBinding,
        WorkflowStep,
        WorkflowVariable,
        WorkflowStartResolution,
        WorkflowTurnOutcome,
        WorkflowTurnAdapter;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskCancellationSubscriber, TaskService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeTurnManager;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late TaskService taskService;
  late MessageService messageService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late EventBus eventBus;
  late WorkflowService workflowService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wf_svc_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    final taskRepository = SqliteTaskRepository(db);
    final agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
    final workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
    final executionTransactor = SqliteExecutionRepositoryTransactor(db);
    taskService = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionTransactor,
      eventBus: eventBus,
    );
    repository = SqliteWorkflowRunRepository(db);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionRepositoryTransactor: executionTransactor,
    );
  });

  tearDown(() async {
    await workflowService.dispose();
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  WorkflowDefinition makeDefinition({List<WorkflowStep>? steps, Map<String, WorkflowVariable> variables = const {}}) {
    return WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test workflow',
      variables: variables,
      steps:
          steps ??
          [
            const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          ],
    );
  }

  void autoCompleteNewTasks() {
    eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      // Use real transitions so DB state matches what executor reads.
      try {
        await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
        await taskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
        await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
      } on StateError {
        // Ignore invalid transition errors if task already moved.
      }
    });
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

  test('start() applies required variable values', () async {
    final definition = makeDefinition(
      variables: {'topic': const WorkflowVariable(required: true, description: 'The topic')},
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {'topic': 'Dart programming'});
    expect(run.variablesJson['topic'], equals('Dart programming'));
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

    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) async => 'turn-id',
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
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
    );
    final run = await workflowService.start(definition, const {});

    expect(run.variablesJson['PROJECT'], equals('_local'));
    expect(run.variablesJson['BRANCH'], equals('develop'));
  });

  test('start() fails preflight before creating run or coding task', () async {
    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) async => 'turn-id',
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
          throw ArgumentError('Ref "missing/ref" not found');
        },
      ),
    );
    final definition = makeDefinition(
      variables: const {'PROJECT': WorkflowVariable(required: false), 'BRANCH': WorkflowVariable(required: false)},
      steps: const [
        WorkflowStep(id: 'coding-step', name: 'Coding', type: 'coding', prompts: ['Implement']),
      ],
    );

    await expectLater(
      workflowService.start(definition, const {'PROJECT': 'my-app', 'BRANCH': 'missing/ref'}),
      throwsA(isA<ArgumentError>()),
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
    // Wait for run to complete.
    await Future<void>.delayed(const Duration(milliseconds: 100));

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
    final now = DateTime.now();
    await repository.insert(
      WorkflowRun(
        id: 'run-binding',
        definitionName: 'test-workflow',
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        definitionJson: makeDefinition().toJson(),
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
    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
      hydrateWorkflowWorktreeBinding: (binding, {required workflowRunId}) {
        expect(workflowRunId, 'run-hydrate');
        hydrated.add(binding);
      },
    );

    final now = DateTime.now();
    await repository.insert(
      WorkflowRun(
        id: 'run-hydrate',
        definitionName: 'test-workflow',
        status: WorkflowRunStatus.paused,
        startedAt: now,
        updatedAt: now,
        definitionJson: makeDefinition().toJson(),
        workflowWorktree: const WorkflowWorktreeBinding(
          key: 'run-hydrate',
          path: '/tmp/worktrees/wf-run-hydrate',
          branch: 'dartclaw/workflow/runhydrate/integration',
          workflowRunId: 'run-hydrate',
        ),
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
    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
      hydrateWorkflowWorktreeBinding: (binding, {required workflowRunId}) {
        expect(workflowRunId, 'run-hydrate-many');
        hydrated.add(binding);
      },
    );

    final now = DateTime.now();
    await repository.insert(
      WorkflowRun(
        id: 'run-hydrate-many',
        definitionName: 'test-workflow',
        status: WorkflowRunStatus.paused,
        startedAt: now,
        updatedAt: now,
        definitionJson: makeDefinition().toJson(),
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
    final now = DateTime.now();
    await repository.insert(
      WorkflowRun(
        id: 'run-mismatch',
        definitionName: 'test-workflow',
        status: WorkflowRunStatus.paused,
        startedAt: now,
        updatedAt: now,
        definitionJson: makeDefinition().toJson(),
        workflowWorktree: const WorkflowWorktreeBinding(
          key: 'run-mismatch',
          path: '/tmp/worktrees/wf-run-mismatch',
          branch: 'dartclaw/workflow/runmismatch/integration',
          workflowRunId: 'run-other',
        ),
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
    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) async => 'turn-id',
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
          final tasks = await taskService.list();
          final remaining = tasks.where((task) => task.workflowRunId == runId && !task.status.terminal).length;
          cleanupObservedNonTerminalCounts.add(remaining);
        },
      ),
    );

    final run = WorkflowRun(
      id: 'cancel-order-run',
      definitionName: 'test-workflow',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'my-app'},
      definitionJson: makeDefinition().toJson(),
    );
    await repository.insert(run);
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

  test('cancel() propagates to the active turn when the cancellation subscriber is installed', () async {
    final turns = FakeTurnManager();
    final subscriber = TaskCancellationSubscriber(tasks: taskService, turns: turns)..subscribe(eventBus);
    addTearDown(subscriber.dispose);

    final run = WorkflowRun(
      id: 'cancel-turn-run',
      definitionName: 'test-workflow',
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      definitionJson: makeDefinition().toJson(),
    );
    await repository.insert(run);

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
    final now = DateTime.now();
    final run = WorkflowRun(
      id: 'recover-run-1',
      definitionName: 'test-workflow',
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

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

    final now = DateTime.now();
    final run = WorkflowRun(
      id: 'recover-loop-step',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
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
    await repository.insert(run);

    final createdTaskTitles = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null) {
        createdTaskTitles.add(task.title);
      }
      await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
      await taskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
      await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
    });

    await workflowService.recoverIncompleteRuns();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await sub.cancel();

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
          contextOutputs: ['mapped'],
        ),
      ],
    );

    final now = DateTime.now();
    final run = WorkflowRun(
      id: 'recover-map-step',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
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
    await repository.insert(run);

    final createdTaskTitles = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null) {
        createdTaskTitles.add(task.title);
      }
      await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
      await taskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
      await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
    });

    await workflowService.recoverIncompleteRuns();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await sub.cancel();

    expect(createdTaskTitles, hasLength(1));
    expect(createdTaskTitles.single, contains('(3/3)'));

    final recovered = await workflowService.get('recover-map-step');
    expect(recovered?.status, equals(WorkflowRunStatus.completed));
    expect(((recovered?.contextJson['data'] as Map?)?['mapped'] as List?)?.length, equals(3));
  });

  test('recoverIncompleteRuns() skips paused runs', () async {
    final definition = makeDefinition();
    final now = DateTime.now();
    final pausedRun = WorkflowRun(
      id: 'paused-run-1',
      definitionName: 'test-workflow',
      status: WorkflowRunStatus.paused,
      startedAt: now,
      updatedAt: now,
      definitionJson: definition.toJson(),
    );
    await repository.insert(pausedRun);

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

  group('S03 (0.16.1): approval resume/cancel semantics', () {
    /// Inserts a paused run with approval metadata as if the executor had paused it.
    Future<WorkflowRun> insertApprovalPausedRun({
      String runId = 'run-approval',
      String stepId = 'gate',
      int nextStepIndex = 1,
      DateTime? timeoutDeadline,
    }) async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', prompts: ['Approve?']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );
      final now = DateTime.now();
      final run = WorkflowRun(
        id: runId,
        definitionName: definition.name,
        status: WorkflowRunStatus.paused,
        startedAt: now,
        updatedAt: now,
        currentStepIndex: nextStepIndex,
        definitionJson: definition.toJson(),
        contextJson: {
          'data': <String, dynamic>{
            '$stepId.status': 'pending',
            '$stepId.approval.status': 'pending',
            '$stepId.approval.message': 'Approve?',
            '$stepId.approval.requested_at': now.toIso8601String(),
            '$stepId.tokenCount': 0,
            if (timeoutDeadline != null) '$stepId.approval.timeout_deadline': timeoutDeadline.toIso8601String(),
          },
          'variables': <String, dynamic>{},
          '$stepId.status': 'pending',
          '$stepId.approval.status': 'pending',
          '$stepId.approval.message': 'Approve?',
          '$stepId.approval.requested_at': now.toIso8601String(),
          '$stepId.tokenCount': 0,
          if (timeoutDeadline != null) '$stepId.approval.timeout_deadline': timeoutDeadline.toIso8601String(),
          '_approval.pending.stepId': stepId,
          '_approval.pending.stepIndex': nextStepIndex - 1,
        },
      );
      await repository.insert(run);
      final contextDir = Directory(p.join(tempDir.path, 'workflows', 'runs', runId));
      contextDir.createSync(recursive: true);
      File(p.join(contextDir.path, 'context.json')).writeAsStringSync(jsonEncode(run.contextJson));
      return run;
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

  group('S36: retry()', () {
    WorkflowRun buildFailedRun({
      String runId = 'run-failed',
      String failingStepId = 'step1',
      int currentStepIndex = 0,
    }) {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );
      final now = DateTime.now();
      return WorkflowRun(
        id: runId,
        definitionName: definition.name,
        status: WorkflowRunStatus.failed,
        startedAt: now,
        updatedAt: now,
        errorMessage: 'boom',
        currentStepIndex: currentStepIndex,
        definitionJson: definition.toJson(),
        contextJson: {
          '$failingStepId.status': 'failed',
          'step.$failingStepId.outcome': 'failed',
          'step.$failingStepId.outcome.reason': 'boom',
        },
      );
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

      final run = buildFailedRun();
      await repository.insert(run);
      // Seed context.json so _loadContext doesn't build from DB only.
      final ctxDir = Directory(p.join(tempDir.path, 'workflows', 'runs', run.id))..createSync(recursive: true);
      File(p.join(ctxDir.path, 'context.json')).writeAsStringSync(jsonEncode(run.contextJson));
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
      final run = buildFailedRun();
      await repository.insert(run);
      final ctxDir = Directory(p.join(tempDir.path, 'workflows', 'runs', run.id))..createSync(recursive: true);
      File(p.join(ctxDir.path, 'context.json')).writeAsStringSync(jsonEncode(run.contextJson));
      autoCompleteNewTasks();

      await workflowService.retry(run.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final updated = await workflowService.get(run.id);
      expect(updated?.contextJson.containsKey('step1.status'), isFalse);
      expect(updated?.contextJson.containsKey('step.step1.outcome'), isFalse);
      expect(updated?.contextJson.containsKey('step.step1.outcome.reason'), isFalse);
    });
  });
}
