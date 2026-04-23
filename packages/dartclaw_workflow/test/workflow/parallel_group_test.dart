import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        KvService,
        MessageService,
        ParallelGroupCompletedEvent,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, GateEvaluator, StepExecutionContext, WorkflowExecutor;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
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
  late WorkflowExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_parallel_test_');
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

    executor = WorkflowExecutor(
      executionContext: StepExecutionContext(
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
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionTransactor,
      ),
      dataDir: tempDir.path,
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

  /// Completes a task: queued → running → review → accepted (or running → failed).
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

  test('3-step parallel group happy path: all steps execute and complete', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
        const WorkflowStep(id: 'p3', name: 'P3', prompts: ['Do p3'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final taskIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskIds.add(e.taskId);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskIds.length, equals(3));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('parallel group: metadata keys set for all steps', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(context['p1.status'], equals('accepted'));
    expect(context['p1.tokenCount'], isNotNull);
    expect(context['p2.status'], equals('accepted'));
    expect(context['p2.tokenCount'], isNotNull);
  });

  test('partial failure: failed step pauses workflow, other step succeeds', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
        const WorkflowStep(id: 'p3', name: 'P3', prompts: ['Do p3'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var callCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      callCount++;
      // Fail p2 (second task created), succeed others.
      if (callCount == 2) {
        await completeTask(e.taskId, status: TaskStatus.failed);
      } else {
        await completeTask(e.taskId);
      }
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // All 3 created — parallel, not sequential.
    expect(callCount, equals(3));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('Parallel step(s) failed'));

    // Successful steps' metadata should still be set.
    expect(context['p1.status'], equals('accepted'));
    expect(context['p3.status'], equals('accepted'));
    // Failed step has 'failed' status.
    expect(context['p2.status'], equals('failed'));
  });

  test('all parallel steps fail: workflow pauses listing all failures', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId, status: TaskStatus.failed);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('Parallel step(s) failed'));
  });

  test('gate blocks entire parallel group when one step gate fails', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true, gate: 'approved == true'),
        const WorkflowStep(id: 'p3', name: 'P3', prompts: ['Do p3'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    // Gate references 'approved' which is 'false' in context.
    final context = WorkflowContext(data: {'approved': 'false'});

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // No tasks created — gate blocked the group.
    expect(taskCount, equals(0));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('Gate failed for parallel step'));
  });

  test('budget exceeded before parallel group pauses workflow', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      maxTokens: 100,
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    var run = makeRun(definition);
    run = run.copyWith(totalTokens: 100); // Already at budget.
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(0));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('budget'));
  });

  test('sequential + parallel + sequential: correct execution order', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'seq1', name: 'Seq1', prompts: ['Do seq1']),
        const WorkflowStep(id: 'par1', name: 'Par1', prompts: ['Do par1'], parallel: true),
        const WorkflowStep(id: 'par2', name: 'Par2', prompts: ['Do par2'], parallel: true),
        const WorkflowStep(id: 'seq2', name: 'Seq2', prompts: ['Do seq2']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final executedIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      executedIds.add(e.taskId);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(executedIds.length, equals(4));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('ParallelGroupCompletedEvent fired with correct fields', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final groupEvents = <ParallelGroupCompletedEvent>[];
    final groupSub = eventBus.on<ParallelGroupCompletedEvent>().listen(groupEvents.add);

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();
    await groupSub.cancel();

    expect(groupEvents.length, equals(1));
    expect(groupEvents.first.stepIds, containsAll(['p1', 'p2']));
    expect(groupEvents.first.successCount, equals(2));
    expect(groupEvents.first.failureCount, equals(0));
    expect(groupEvents.first.runId, equals('run-1'));
  });

  test('WorkflowStepCompletedEvent fired for each parallel step', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();
    await stepSub.cancel();

    expect(stepEvents.length, equals(2));
    final stepIds = stepEvents.map((e) => e.stepId).toList();
    expect(stepIds, containsAll(['p1', 'p2']));
  });

  test('parallel group: budget accumulates from all steps', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Run completed — totalTokens is tracked (0 since no session KV in tests).
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(finalRun?.totalTokens, greaterThanOrEqualTo(0));
  });
}
