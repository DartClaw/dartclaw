import 'dart:async';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        KvService,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        MessageService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitBootstrapResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowGitStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, GateEvaluator, WorkflowExecutor, WorkflowTurnAdapter, WorkflowTurnOutcome;
import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowExecutionCursor;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late SqliteTaskRepository taskRepository;
  late TaskService taskService;
  late MessageService messageService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late SqliteAgentExecutionRepository agentExecutionRepository;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository;
  late SqliteExecutionRepositoryTransactor executionRepositoryTransactor;
  late EventBus eventBus;
  late WorkflowExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_map_step_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskRepository = SqliteTaskRepository(db);
    agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
    workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
    executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(db);
    taskService = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionRepositoryTransactor,
      eventBus: eventBus,
    );
    repository = SqliteWorkflowRunRepository(db);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    executor = WorkflowExecutor(
      taskService: taskService,
      eventBus: eventBus,
      kvService: kvService,
      repository: repository,
      gateEvaluator: GateEvaluator(),
      contextExtractor: ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: tempDir.path,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
      ),
      dataDir: tempDir.path,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionTransactor: executionRepositoryTransactor,
    );
  });

  tearDown(() async {
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  WorkflowRun makeRun(WorkflowDefinition definition) {
    final now = DateTime.now();
    return WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
    );
  }

  /// Simulates task completion: queued → running → terminal.
  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // May already be running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // May already be in review.
      }
    }
    await taskService.transition(taskId, status, trigger: 'test');
  }

  group('core map execution', () {
    test('workflow-owned map coding task auto-advances on accepted terminal status', () async {
      final definition = WorkflowDefinition(
        name: 'map-auto-accept',
        description: 'Workflow-owned map tasks should unblock on accepted.',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            contextOutputs: ['story_result'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'map-review-ready-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
          workflowStepExecutionRepository: workflowStepExecutionRepository,
        ),
        dataDir: tempDir.path,
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionRepositoryTransactor,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async => const WorkflowGitPromotionSuccess(commitSha: 'abc123'),
        ),
      );

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        await taskService.updateFields(
          task.id,
          worktreeJson: {
            'path': p.join(tempDir.path, 'worktrees', task.id),
            'branch': 'story-s01',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        try {
          await taskService.transition(task.id, TaskStatus.running, trigger: 'test');
        } on StateError {
          // Already running.
        }
        await taskService.transition(task.id, TaskStatus.accepted, trigger: 'test');
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('map-review-ready-run');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('3-item array creates 3 tasks', () async {
      final collection = [
        {'id': 's01', 'name': 'Story 1'},
        {'id': 's02', 'name': 'Story 2'},
        {'id': 's03', 'name': 'Story 3'},
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['produce'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 3,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: '3 tasks should be created, one per item');
    });

    test('worktree auto resolves to inline for serial map execution', () async {
      final repoBackedExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
          workflowStepExecutionRepository: workflowStepExecutionRepository,
        ),
        dataDir: tempDir.path,
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionRepositoryTransactor,
      );
      final definition = WorkflowDefinition(
        name: 'map-inline-auto',
        description: 'Map auto worktree serial resolution',
        gitStrategy: const WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: 'auto')),
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: 'coding',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 1,
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = ['story-1'];
      final modeCompleter = Completer<String?>();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task != null && !modeCompleter.isCompleted) {
          final workflowGit = (await workflowStepExecutionRepository.getByTaskId(task.id))?.git;
          modeCompleter.complete(workflowGit?['worktree'] as String?);
        }
        await completeTask(e.taskId);
      });

      await repoBackedExecutor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(await modeCompleter.future, 'inline');
    });

    test('worktree auto resolves to per-map-item for parallel map execution', () async {
      final repoBackedExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
          workflowStepExecutionRepository: workflowStepExecutionRepository,
        ),
        dataDir: tempDir.path,
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionRepositoryTransactor,
      );
      final definition = WorkflowDefinition(
        name: 'map-per-item-auto',
        description: 'Map auto worktree parallel resolution',
        gitStrategy: const WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: 'auto')),
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: 'coding',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 2,
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = ['story-1'];
      final modeCompleter = Completer<String?>();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task != null && !modeCompleter.isCompleted) {
          final workflowGit = (await workflowStepExecutionRepository.getByTaskId(task.id))?.git;
          modeCompleter.complete(workflowGit?['worktree'] as String?);
        }
        await completeTask(e.taskId);
      });

      await repoBackedExecutor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(await modeCompleter.future, 'per-map-item');
    });

    test('worktree auto resolves to per-map-item for unlimited map execution', () async {
      final repoBackedExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
          workflowStepExecutionRepository: workflowStepExecutionRepository,
        ),
        dataDir: tempDir.path,
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionRepositoryTransactor,
      );
      final definition = WorkflowDefinition(
        name: 'map-unlimited-auto',
        description: 'Map auto worktree unlimited resolution',
        gitStrategy: const WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: 'auto')),
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: 'coding',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 'unlimited',
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = ['story-1'];
      final modeCompleter = Completer<String?>();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task != null && !modeCompleter.isCompleted) {
          final workflowGit = (await workflowStepExecutionRepository.getByTaskId(task.id))?.git;
          modeCompleter.complete(workflowGit?['worktree'] as String?);
        }
        await completeTask(e.taskId);
      });

      await repoBackedExecutor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(await modeCompleter.future, 'per-map-item');
    });

    test('results collected in index order (not completion order)', () async {
      final collection = ['item0', 'item1', 'item2'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      // Complete tasks in reverse order (2, 1, 0).
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      // Run executor in background, manually complete tasks in reverse.
      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all 3 tasks to be created.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete in reverse order.
      for (final id in taskIds.reversed) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Results should be index-ordered (3 slots, all null from default extraction).
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(3));
    });

    test('maxParallel: 1 (default) executes sequentially', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            // maxParallel omitted → defaults to 1 (sequential)
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
        concurrent--;
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(maxConcurrent, equals(1), reason: 'maxParallel default is 1 (sequential)');
    });

    test('maxParallel: "unlimited" dispatches all items', () async {
      final collection = ['a', 'b', 'c', 'd', 'e'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 'unlimited',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all tasks to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 5;
      });
      await sub.cancel();

      for (final id in taskIds) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      expect(taskIds.length, equals(5));
    });

    test('map iterations preserve project binding for coding tasks', () async {
      final collection = ['story-a', 'story-b'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Project map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: 'coding',
            project: 'my-app',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 2,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      final projectIds = <String?>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        projectIds.add(task?.projectId);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(projectIds, equals(['my-app', 'my-app']));
    });
  });

  group('error handling', () {
    test('promotion-aware map rejects unknown dependency IDs before dispatch', () async {
      final definition = WorkflowDefinition(
        name: 'promotion-aware-map',
        description: 'Unknown dependency validation',
        gitStrategy: const WorkflowGitStrategy(
          bootstrap: true,
          worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: 'coding',
            project: 'my-project',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 2,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'run-unknown-deps',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {
              'id': 'S01',
              'dependencies': ['S99'],
            },
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final promotionAwareExecutor = WorkflowExecutor(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: taskService,
          messageService: messageService,
          dataDir: tempDir.path,
          workflowStepExecutionRepository: workflowStepExecutionRepository,
        ),
        dataDir: tempDir.path,
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionRepositoryTransactor,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
              const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
        ),
      );

      await promotionAwareExecutor.execute(run, definition, context);

      final finalRun = await repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.paused);
      expect(finalRun?.errorMessage, contains('unknown dependency IDs'));
      final tasks = await taskService.list();
      expect(tasks.where((t) => t.workflowRunId == run.id), isEmpty, reason: 'Validation should fail before dispatch');
    });

    test('empty collection succeeds with empty result array', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = <Object?>[];

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(0));
    });

    test('mapOver references null key → step fails', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      // 'items' not set in context — should be null.
      final context = WorkflowContext();

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('null or missing'));
    });

    test('mapOver references non-List → step fails', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = 'not a list';

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('not a List'));
    });

    test('collection exceeding maxItems → step fails with decomposition hint', () async {
      final collection = List.generate(5, (i) => 'item$i');
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxItems: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('maxItems'));
      expect(updatedRun?.errorMessage, contains('decompos'));
    });

    test('single iteration failure — others continue, result array has error object', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      // Fail the second task (index 1), succeed the others.
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete tasks: fail index 1, succeed others.
      for (var i = 0; i < taskIds.length; i++) {
        await completeTask(taskIds[i], status: i == 1 ? TaskStatus.failed : TaskStatus.accepted);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Step should be paused (has failures).
      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));

      // Results array is still stored in context before pausing.
      expect(context['mapped'], isA<List<Object?>>());
      final mapped = context['mapped'] as List;
      expect(mapped.length, equals(3));

      // Index 1 should be an error object.
      final errorResult = mapped[1] as Map;
      expect(errorResult['error'], isTrue);
      expect(errorResult, contains('message'));
    });

    test('circular dependency detected at step start → step fails', () async {
      final collection = [
        {
          'id': 's01',
          'name': 'S1',
          'dependencies': ['s02'],
        },
        {
          'id': 's02',
          'name': 'S2',
          'dependencies': ['s01'],
        },
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Dep test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('Circular dependency'));
    });
  });

  group('dependency ordering', () {
    test('item with dependency not dispatched until dep completes', () async {
      final collection = [
        {'id': 's01', 'name': 'S1'},
        {
          'id': 's02',
          'name': 'S2',
          'dependencies': ['s01'],
        },
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Dep test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 3,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      // Track order of task creation.
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for first task to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.isEmpty;
      });

      // At this point only s01 (index 0) should be dispatched.
      expect(taskIds.length, equals(1), reason: 's02 blocked by s01 dependency');

      // Complete s01.
      await completeTask(taskIds[0]);
      await Future<void>.delayed(Duration.zero);

      // Wait for s02 to be dispatched.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 2;
      });
      await sub.cancel();

      // Complete s02.
      await completeTask(taskIds[1]);
      await executorFuture;

      expect(taskIds.length, equals(2));
      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('items without id field are all independent (dispatched immediately)', () async {
      final collection = ['plain-a', 'plain-b', 'plain-c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'No dep test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // All 3 should be dispatched immediately.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: 'no deps means all dispatched at once');

      for (final id in taskIds) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;
    });
  });

  group('events', () {
    test('MapIterationCompletedEvent fired per iteration with correct fields', () async {
      final collection = ['x', 'y'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Event test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final iterEvents = <MapIterationCompletedEvent>[];
      final iterSub = eventBus.on<MapIterationCompletedEvent>().listen(iterEvents.add);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();
      await iterSub.cancel();

      expect(iterEvents.length, equals(2));
      expect(iterEvents.map((e) => e.iterationIndex).toSet(), equals({0, 1}));
      for (final e in iterEvents) {
        expect(e.runId, equals('run-1'));
        expect(e.stepId, equals('map'));
        expect(e.totalIterations, equals(2));
        expect(e.success, isTrue);
      }
    });

    test('MapStepCompletedEvent fired with aggregate stats', () async {
      final collection = ['x', 'y', 'z'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Event test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      MapStepCompletedEvent? completedEvent;
      final completeSub = eventBus.on<MapStepCompletedEvent>().listen((e) => completedEvent = e);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();
      await completeSub.cancel();

      expect(completedEvent, isNotNull);
      expect(completedEvent!.runId, equals('run-1'));
      expect(completedEvent!.stepId, equals('map'));
      expect(completedEvent!.stepName, equals('Map'));
      expect(completedEvent!.totalIterations, equals(3));
      expect(completedEvent!.successCount, equals(3));
      expect(completedEvent!.failureCount, equals(0));
      expect(completedEvent!.cancelledCount, equals(0));
    });

    test('persists map progress checkpoints between sequential map iterations', () async {
      final collection = ['a', 'b', 'c'];
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

      var run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final queuedTitles = <String>[];
      final checkpointReady = Completer<void>();
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        queuedTitles.add(task.title);
        if (queuedTitles.length == 2 && !checkpointReady.isCompleted) {
          checkpointReady.complete();
        }
        await completeTask(e.taskId);
      });

      final executeFuture = executor.execute(run, definition, context);
      await checkpointReady.future;

      final checkpointed = await repository.getById('run-1');
      expect(checkpointed?.executionCursor?.nodeId, 'map');
      expect(checkpointed?.executionCursor?.completedIndices, [0]);

      await executeFuture;
      await sub.cancel();

      expect(queuedTitles, ['map-recovery — Map (1/3)', 'map-recovery — Map (2/3)', 'map-recovery — Map (3/3)']);
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('maxParallel resolution', () {
    test('maxParallel as int is used directly', () async {
      final collection = List.generate(4, (i) => 'item$i');
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final taskIds = <String>[];

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        concurrent++;
        taskIds.add(e.taskId);
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Manually complete tasks to control concurrency observation.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        if (taskIds.isNotEmpty) {
          final id = taskIds.removeAt(0);
          await completeTask(id);
          concurrent--;
        }
        final updatedRun = await repository.getById('run-1');
        return updatedRun?.status == WorkflowRunStatus.running;
      });
      await sub.cancel();
      await executorFuture;

      expect(maxConcurrent, lessThanOrEqualTo(2));
    });

    test('invalid maxParallel string → step fails', () async {
      final collection = ['a', 'b'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 'not-a-number',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('maxParallel'));
    });
  });

  group('S19: foreach execution', () {
    test('foreach iterates items and runs child steps sequentially per item', () async {
      final collection = [
        {'id': 'S01', 'title': 'Story 1'},
        {'id': 'S02', 'title': 'Story 2'},
        {'id': 'S03', 'title': 'Story 3'},
      ];
      final definition = WorkflowDefinition(
        name: 'foreach-test',
        description: 'Foreach execution test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            type: 'foreach',
            mapOver: 'stories',
            foreachSteps: ['implement', 'validate'],
            contextOutputs: ['story_results'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Build {{map.item}}'], type: 'coding'),
          WorkflowStep(id: 'validate', name: 'Validate', prompts: ['Validate {{map.item}}']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      // Track task creation order to verify sequential child-step execution.
      var taskCount = 0;
      final taskTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        final task = await taskService.get(e.taskId);
        if (task != null) taskTitles.add(task.title);
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      // 3 items × 2 child steps = 6 tasks.
      expect(taskCount, 6);
      // Task titles should alternate implement/validate for sequential per-item execution.
      expect(taskTitles.length, 6);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('foreach with empty collection succeeds with empty results', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-empty',
        description: 'Empty foreach',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'stories',
            foreachSteps: ['child'],
            contextOutputs: ['results'],
          ),
          WorkflowStep(id: 'child', name: 'Child', prompts: ['p']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = <Map<String, dynamic>>[];

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['results'], isA<List<Object?>>());
      expect((context['results'] as List<Object?>), isEmpty);
    });

    test('foreach child step failure records iteration failure', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-fail',
        description: 'Foreach with child failure',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['step-a', 'step-b'],
            contextOutputs: ['results'],
          ),
          WorkflowStep(id: 'step-a', name: 'A', prompts: ['p']),
          WorkflowStep(id: 'step-b', name: 'B', prompts: ['p']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = ['item1', 'item2'];

      var taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        if (taskCount == 1) {
          // Fail the first child step of item1 — item1 should fail, item2 proceeds.
          await completeTask(e.taskId, status: TaskStatus.failed);
        } else {
          await completeTask(e.taskId);
        }
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      // item1: step-a fails → no step-b for item1. item2 still runs (step-a + step-b).
      // Total: 3 tasks (item1: 1, item2: 2).
      expect(taskCount, 3);

      // Foreach with a failed iteration pauses the workflow (consistent with map step behavior).
      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
    });

    test('foreach fires MapIterationCompletedEvent per item', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-events',
        description: 'Event test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['child'],
            contextOutputs: ['results'],
          ),
          WorkflowStep(id: 'child', name: 'Child', prompts: ['p']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = ['a', 'b'];

      final iterEvents = <MapIterationCompletedEvent>[];
      final iterSub = eventBus.on<MapIterationCompletedEvent>().listen(iterEvents.add);

      final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await taskSub.cancel();
      await iterSub.cancel();

      expect(iterEvents.length, 2);
      expect(iterEvents[0].iterationIndex, 0);
      expect(iterEvents[1].iterationIndex, 1);
      expect(iterEvents[0].stepId, 'fe');
    });

    test('foreach fires MapStepCompletedEvent with aggregate stats', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-complete-event',
        description: 'Completion event test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'items',
            foreachSteps: ['child'],
            contextOutputs: ['results'],
          ),
          WorkflowStep(id: 'child', name: 'Child', prompts: ['p']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = ['a', 'b'];

      MapStepCompletedEvent? completionEvent;
      final completeSub = eventBus.on<MapStepCompletedEvent>().listen((e) => completionEvent = e);

      final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await taskSub.cancel();
      await completeSub.cancel();

      expect(completionEvent, isNotNull);
      expect(completionEvent!.stepId, 'fe');
      expect(completionEvent!.totalIterations, 2);
    });

    test('foreach crash recovery resumes from crashed iteration without replaying completed', () async {
      final collection = [
        {'id': 'S01'},
        {'id': 'S02'},
        {'id': 'S03'},
      ];
      final definition = WorkflowDefinition(
        name: 'foreach-recovery',
        description: 'Recovery test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'stories',
            foreachSteps: ['child'],
            contextOutputs: ['results'],
          ),
          WorkflowStep(id: 'child', name: 'Child', prompts: ['Do {{map.item}}']),
        ],
      );

      final run = makeRun(definition);
      // Seed cursor: iteration 0 completed, iterations 1 and 2 pending.
      final foreachCursor = WorkflowExecutionCursor.foreach(
        stepId: 'fe',
        stepIndex: 1, // index of the foreach controller in the step list
        totalItems: 3,
        completedIndices: [0],
        resultSlots: [
          {'child': {}},
          null,
          null,
        ],
      );
      final seededRun = run.copyWith(
        executionCursor: foreachCursor,
        contextJson: {
          'stories': collection,
          '_foreach.current.stepId': 'fe',
          '_foreach.current.total': 3,
          '_foreach.current.completedIndices': [0],
          '_foreach.current.failedIndices': <int>[],
          '_foreach.current.cancelledIndices': <int>[],
        },
      );
      await repository.insert(seededRun);
      final context = WorkflowContext()..['stories'] = collection;

      var taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      // Resume: the executor should skip iteration 0 and run iterations 1 and 2.
      await executor.execute(seededRun, definition, context, startCursor: foreachCursor);
      await sub.cancel();

      // Only 2 tasks (for iterations 1 and 2), not 3.
      expect(taskCount, 2, reason: 'Already-completed iteration 0 should not be replayed');

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('foreach exceeding maxItems fails the step', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-max',
        description: 'MaxItems test',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: 'foreach',
            mapOver: 'items',
            maxItems: 2,
            foreachSteps: ['child'],
            contextOutputs: ['results'],
          ),
          WorkflowStep(id: 'child', name: 'Child', prompts: ['p']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = ['a', 'b', 'c'];

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('maxItems'));
    });
  });
}
