@Tags(['component'])
library;

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        KvService,
        LoopIterationCompletedEvent,
        MessageService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowLoop,
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

const _inlineLoopExecutionYaml = '''
name: ordered-inline-loop
description: Inline loop authored in step order
steps:
  - id: gap-analysis
    name: Gap Analysis
    prompt: Analyze the implementation
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    exitGate: re-review.status == accepted
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
      - id: re-review
        name: Re-review
        prompt: Verify the fixes
  - id: update-state
    name: Update State
    prompt: Record the final result
''';

const _inlineEntryGateLoopYaml = '''
name: ordered-inline-entry-gate-loop
description: Inline loop with entry gate
steps:
  - id: gap-analysis
    name: Gap Analysis
    prompt: Analyze the implementation
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    entryGate: gap-analysis.findings_count > 0
    exitGate: re-review.status == accepted
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
      - id: re-review
        name: Re-review
        prompt: Verify the fixes
  - id: update-state
    name: Update State
    prompt: Record the final result
''';

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
    tempDir = Directory.systemTemp.createTempSync('dartclaw_loop_test_');
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

  /// Completes a task: queued → running → [review →] terminal.
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

  test('exit gate passes on iteration 1: loop executes once', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'loop-step1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['loop-step1'], maxIterations: 5, exitGate: 'loop.loop1.iteration == 1'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var iterationCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      iterationCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(iterationCount, equals(1));
    expect(context['loop.loop1.iteration'], equals(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('exit gate passes on iteration 2: loop executes twice', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 5, exitGate: 'loop.loop1.iteration == 2'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(2));
    expect(context['loop.loop1.iteration'], equals(2));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('maxIterations circuit breaker: pauses when gate never passes', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(
          id: 'loop1',
          steps: ['ls1'],
          maxIterations: 2,
          exitGate: 'never.passes == true', // Will never be true.
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(2)); // 2 iterations executed.
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('max iterations'));
    expect(finalRun?.errorMessage, contains('2'));
    expect(finalRun?.errorMessage, contains('loop1'));
  });

  test('loop step failure pauses workflow with iteration context', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 3, exitGate: 'ls1.status == accepted'),
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
    expect(finalRun?.errorMessage, contains('loop1'));
    expect(finalRun?.errorMessage, contains('LS1'));
  });

  test('loop.iteration counter set correctly each iteration', () async {
    final iterationsObserved = <int>[];
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1 iter {{context.loop.loop1.iteration}}']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 3, exitGate: 'loop.loop1.iteration == 3'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final iter = context['loop.loop1.iteration'] as int?;
      if (iter != null) iterationsObserved.add(iter);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(iterationsObserved, containsAll([1, 2, 3]));
    expect(context['loop.loop1.iteration'], equals(3));
  });

  test('context accumulated across iterations: latest output wins', () async {
    var callCount = 0;
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1'], contextOutputs: ['analysis']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 3, exitGate: 'loop.loop1.iteration == 2'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      callCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(callCount, equals(2));
    // Context key 'ls1.status' should reflect last iteration.
    expect(context['ls1.status'], equals('accepted'));
  });

  test('loop cancellation: stops mid-iteration', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 5, exitGate: 'loop.loop1.iteration == 5'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    var cancelled = false;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      cancelled = true; // Cancel after first loop task.
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context, isCancelled: () => cancelled);
    await sub.cancel();

    // Only 1 task executed before cancellation was detected.
    expect(taskCount, lessThanOrEqualTo(2));
  });

  test('multiple loops execute in declaration order', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
        const WorkflowStep(id: 'ls2', name: 'LS2', prompts: ['Do ls2']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 3, exitGate: 'loop.loop1.iteration == 1'),
        const WorkflowLoop(id: 'loop2', steps: ['ls2'], maxIterations: 3, exitGate: 'loop.loop2.iteration == 1'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Each loop runs 1 iteration = 2 tasks total.
    expect(taskCount, equals(2));
    expect(context['loop.loop1.iteration'], equals(1));
    expect(context['loop.loop2.iteration'], equals(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('sequential steps + loop: authored-order traversal executes the loop in place', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'seq1', name: 'Seq1', prompts: ['Do seq1']),
        const WorkflowStep(id: 'seq2', name: 'Seq2', prompts: ['Do seq2']),
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 2, exitGate: 'loop.loop1.iteration == 1'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // 2 sequential steps + 1 loop step.
    expect(taskCount, equals(3));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('LoopIterationCompletedEvent fired after each iteration', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 3, exitGate: 'loop.loop1.iteration == 2'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final loopEvents = <LoopIterationCompletedEvent>[];
    final loopSub = eventBus.on<LoopIterationCompletedEvent>().listen(loopEvents.add);

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();
    await loopSub.cancel();

    expect(loopEvents.length, equals(2));
    expect(loopEvents[0].iteration, equals(1));
    expect(loopEvents[0].gateResult, isFalse);
    expect(loopEvents[1].iteration, equals(2));
    expect(loopEvents[1].gateResult, isTrue);
    expect(loopEvents[0].loopId, equals('loop1'));
    expect(loopEvents[0].maxIterations, equals(3));
  });

  test('loop crash recovery: resumes from specified loop + iteration', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 3, exitGate: 'loop.loop1.iteration == 2'),
      ],
    );

    final run = makeRun(definition);
    // Seed loop tracking state — as if crashed mid iteration 2.
    final seededRun = run.copyWith(contextJson: {'_loop.current.id': 'loop1', '_loop.current.iteration': 2});
    await repository.insert(seededRun);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    // Resume from loop index 0, iteration 2 (the executor seeks back to the loop node).
    await executor.execute(
      seededRun,
      definition,
      context,
      startFromStepIndex: definition.steps.length, // Force loop-node resume resolution.
      startFromLoopIndex: 0,
      startFromLoopIteration: 2,
    );
    await sub.cancel();

    // Only 1 task: iteration 2 (gate passes on iteration 2).
    expect(taskCount, equals(1));
    expect(context['loop.loop1.iteration'], equals(2));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('step with parallel:true inside loop executes sequentially (no crash)', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        // parallel:true inside loop should be ignored (warning logged).
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1'], parallel: true),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 2, exitGate: 'loop.loop1.iteration == 1'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Executes 1 task sequentially (parallel flag ignored in loop).
    expect(taskCount, equals(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('loop budget exceeded: pauses with budget message', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      maxTokens: 100,
      steps: [
        const WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 3, exitGate: 'loop.loop1.iteration == 3'),
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

  // Loop finalizer tests ────────────────────────────────────────────────

  test('finalizer runs after gate pass — workflow completes', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: const [
        WorkflowStep(id: 'loop-step', name: 'Loop Step', prompts: ['Do loop']),
        WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['Summarize']),
      ],
      loops: const [
        WorkflowLoop(
          id: 'loop1',
          steps: ['loop-step'],
          maxIterations: 3,
          exitGate: 'loop.loop1.iteration == 1',
          finally_: 'summarize',
        ),
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

    // 1 loop iteration + 1 finalizer = 2 tasks.
    expect(taskIds.length, equals(2));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('finalizer runs after maxIterations — workflow pauses', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: const [
        WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
        WorkflowStep(id: 'finalizer', name: 'Finalizer', prompts: ['Finalize']),
      ],
      loops: const [
        WorkflowLoop(
          id: 'loop1',
          steps: ['ls1'],
          maxIterations: 2,
          exitGate: 'never.passes == true',
          finally_: 'finalizer',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // 2 loop iterations + 1 finalizer = 3 tasks.
    expect(taskCount, equals(3));
    final finalRun = await repository.getById('run-1');
    // Loop pauses (maxIterations exceeded), even though finalizer ran.
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('max iterations'));
  });

  test('finalizer runs after step failure — workflow pauses', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: const [
        WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
        WorkflowStep(id: 'cleanup', name: 'Cleanup', prompts: ['Clean up']),
      ],
      loops: const [
        WorkflowLoop(
          id: 'loop1',
          steps: ['ls1'],
          maxIterations: 3,
          exitGate: 'ls1.status == accepted',
          finally_: 'cleanup',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      // First task (ls1) fails; second task (cleanup/finalizer) succeeds.
      if (taskCount == 1) {
        await completeTask(e.taskId, status: TaskStatus.failed);
      } else {
        await completeTask(e.taskId);
      }
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // ls1 failed (1) + cleanup finalizer ran (1) = 2 tasks.
    expect(taskCount, equals(2));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('finalizer failure pauses workflow with finalizer error', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: const [
        WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
        WorkflowStep(id: 'bad-cleanup', name: 'Bad Cleanup', prompts: ['Fail']),
      ],
      loops: const [
        WorkflowLoop(
          id: 'loop1',
          steps: ['ls1'],
          maxIterations: 3,
          exitGate: 'loop.loop1.iteration == 1',
          finally_: 'bad-cleanup',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      // ls1 succeeds, bad-cleanup fails.
      if (taskCount == 1) {
        await completeTask(e.taskId);
      } else {
        await completeTask(e.taskId, status: TaskStatus.failed);
      }
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(2));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('finalizer'));
    expect(finalRun?.errorMessage, contains('Bad Cleanup'));
  });

  test('finalizer accesses loop context (iteration count)', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: const [
        WorkflowStep(
          id: 'ls1',
          name: 'LS1',
          prompts: ['Iter {{context.loop.loop1.iteration}}'],
          contextOutputs: ['result'],
        ),
        WorkflowStep(
          id: 'finalizer',
          name: 'Finalizer',
          prompts: ['Summary after {{context.loop.loop1.iteration}} iterations'],
        ),
      ],
      loops: const [
        WorkflowLoop(
          id: 'loop1',
          steps: ['ls1'],
          maxIterations: 3,
          exitGate: 'loop.loop1.iteration == 2',
          finally_: 'finalizer',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    int? iterationAtFinalizer;
    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      // 3rd task is the finalizer — capture iteration from context.
      if (taskCount == 3) {
        iterationAtFinalizer = context['loop.loop1.iteration'] as int?;
      }
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // 2 loop iterations + 1 finalizer = 3.
    expect(taskCount, equals(3));
    // Finalizer sees iteration = 2 (the iteration at which the gate passed).
    expect(iterationAtFinalizer, equals(2));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('loop without finally works unchanged (no regression)', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: const [
        WorkflowStep(id: 'ls1', name: 'LS1', prompts: ['Do ls1']),
      ],
      loops: const [
        WorkflowLoop(id: 'loop1', steps: ['ls1'], maxIterations: 2, exitGate: 'loop.loop1.iteration == 1'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('inline loop executes in authored order before following sibling steps', () async {
    final definition = WorkflowDefinitionParser().parse(_inlineLoopExecutionYaml);
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['gap-analysis', 'remediate', 're-review', 'update-state']));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('inline loop entry gate skips the loop body when findings_count is zero', () async {
    final definition = WorkflowDefinitionParser().parse(_inlineEntryGateLoopYaml);
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(data: {'gap-analysis.findings_count': 0});

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['gap-analysis', 'update-state']));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('inline loop entry gate executes the loop body when findings_count is positive', () async {
    final definition = WorkflowDefinitionParser().parse(_inlineEntryGateLoopYaml);
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(data: {'gap-analysis.findings_count': 3});

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['gap-analysis', 'remediate', 're-review', 'update-state']));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('legacy loops execute in authored-order model at first loop step without side-table ordering drift', () async {
    final definition = WorkflowDefinition(
      name: 'legacy-side-table',
      description: 'Legacy loops side table compatibility',
      steps: [
        const WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup']),
        const WorkflowStep(id: 'remediate', name: 'Remediate', prompts: ['Fix']),
        const WorkflowStep(id: 'middle', name: 'Middle', prompts: ['Middle']),
        const WorkflowStep(id: 're-review', name: 'Re-review', prompts: ['Review']),
        const WorkflowStep(id: 'after', name: 'After', prompts: ['After']),
      ],
      loops: [
        const WorkflowLoop(
          id: 'legacy-loop',
          steps: ['remediate', 're-review'],
          maxIterations: 2,
          exitGate: 're-review.status == accepted',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['setup', 'remediate', 're-review', 'middle', 'after']));
  });

  test('executor dispatches loop-owned body steps in authored order (smoke test)', () async {
    final definition = WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2 (loop-owned)', prompts: ['Loop body']),
        const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['step2'], maxIterations: 3, exitGate: 'step2.status == accepted'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final executedTaskIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null) executedTaskIds.add(e.taskId);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Authored order: step1 → loop(step2) → step3. Exit gate passes immediately.
    expect(executedTaskIds.length, equals(3));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });
}
