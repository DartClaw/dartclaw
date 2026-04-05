import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ArtifactKind,
        EventBus,
        KvService,
        MessageService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_server/dartclaw_server.dart'
    show ContextExtractor, GateEvaluator, TaskService, WorkflowExecutor;
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
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wf_exec_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
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

  WorkflowRun makeRun(WorkflowDefinition definition, {int stepIndex = 0}) {
    final now = DateTime.now();
    return WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: stepIndex,
      definitionJson: definition.toJson(),
    );
  }

  WorkflowDefinition makeDefinition({
    List<WorkflowStep>? steps,
    int? maxTokens,
    List<WorkflowLoop> loops = const [],
  }) {
    return WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test workflow',
      steps: steps ?? [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
      ],
      loops: loops,
      maxTokens: maxTokens,
    );
  }

  /// Simulates task completion: queued → running → [review →] terminal.
  ///
  /// accepted requires going through review first (queued→running→review→accepted).
  /// failed/cancelled go: queued→running→failed/cancelled.
  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // May already be running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      // Must pass through review to reach accepted/rejected.
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // May already be in review.
      }
    }
    await taskService.transition(taskId, status, trigger: 'test');
  }

  test('3-step sequential workflow executes all steps', () async {
    final definition = makeDefinition(steps: [
      const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
      const WorkflowStep(id: 'step2', name: 'Step 2', prompt: 'Do step 2'),
      const WorkflowStep(id: 'step3', name: 'Step 3', prompt: 'Do step 3'),
    ]);

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    // Fire completions as tasks are created.
    final taskIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
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

  test('context from step 1 is available in step 2 prompt', () async {
    // Step 1 produces output; step 2 uses {{context.research_notes}}.
    final definition = makeDefinition(steps: [
      const WorkflowStep(
        id: 'step1',
        name: 'Research',
        prompt: 'Do research',
        contextOutputs: ['research_notes'],
      ),
      const WorkflowStep(
        id: 'step2',
        name: 'Summarize',
        prompt: 'Summarize: {{context.research_notes}}',
      ),
    ]);

    final run = makeRun(definition);
    await repository.insert(run);

    // Pre-create artifact for step 1 to be read during extraction.
    final capturedTaskIds = <String>[];
    final capturedDescriptions = <String>[];

    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          final task = await taskService.get(e.taskId);
          if (task != null) {
            capturedTaskIds.add(e.taskId);
            capturedDescriptions.add(task.description);

            // Create artifact for step 1 to provide context output.
            if (capturedTaskIds.length == 1) {
              final artifactsDir = Directory(
                p.join(tempDir.path, 'tasks', e.taskId, 'artifacts'),
              );
              artifactsDir.createSync(recursive: true);
              final mdFile = File(p.join(artifactsDir.path, 'output.md'));
              mdFile.writeAsStringSync('Key findings about the topic.');
              await taskService.addArtifact(
                id: 'art-1',
                taskId: e.taskId,
                name: 'output.md',
                kind: ArtifactKind.document,
                path: mdFile.path,
              );
            }
          }
          await completeTask(e.taskId);
        });

    final context = WorkflowContext();
    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(capturedDescriptions.length, equals(2));
    // Step 2 description should contain the extracted content from step 1.
    expect(capturedDescriptions[1], contains('Key findings about the topic.'));
  });

  test('step failure pauses workflow', () async {
    final definition = makeDefinition(steps: [
      const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
      const WorkflowStep(id: 'step2', name: 'Step 2', prompt: 'Do step 2'),
    ]);

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          stepCount++;
          if (stepCount == 1) {
            await completeTask(e.taskId, status: TaskStatus.failed);
          } else {
            await completeTask(e.taskId);
          }
        });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(stepCount, equals(1)); // Step 2 never executed.
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    expect(finalRun?.errorMessage, contains('step1'));
  });

  test('gate failure pauses workflow', () async {
    final definition = makeDefinition(steps: [
      const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
      const WorkflowStep(
        id: 'step2',
        name: 'Step 2',
        prompt: 'Do step 2',
        gate: 'step1.approved == true',
      ),
    ]);

    final run = makeRun(definition);
    await repository.insert(run);

    // Context has step1.approved = false → gate will fail.
    // (step1 execution only writes step1.status/tokenCount, not step1.approved)
    final context = WorkflowContext(data: {'step1.approved': 'false'});

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          stepCount++;
          await completeTask(e.taskId);
        });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Step 1 executes (no gate), step 2 is blocked by gate.
    expect(stepCount, equals(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    expect(finalRun?.errorMessage, contains('Gate failed'));
  });

  test('loop-owned steps are skipped in linear pass', () async {
    final definition = WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
        const WorkflowStep(id: 'step2', name: 'Step 2 (loop-owned)', prompt: 'Loop body'),
        const WorkflowStep(id: 'step3', name: 'Step 3', prompt: 'Do step 3'),
      ],
      loops: [
        const WorkflowLoop(
          id: 'loop1',
          steps: ['step2'],
          maxIterations: 3,
          exitGate: 'step2.status == accepted',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final executedStepIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          final task = await taskService.get(e.taskId);
          if (task != null) executedStepIds.add(e.taskId);
          await completeTask(e.taskId);
        });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Linear pass: step1 and step3 (step2 skipped). Loop pass: step2 runs once
    // (exitGate 'step2.status == accepted' passes immediately). Total: 3 tasks.
    expect(executedStepIds.length, equals(3));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('cancellation token stops execution between steps', () async {
    final definition = makeDefinition(steps: [
      const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
      const WorkflowStep(id: 'step2', name: 'Step 2', prompt: 'Do step 2'),
    ]);

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    var cancelled = false;
    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          stepCount++;
          cancelled = true; // Signal cancellation after step 1.
          await completeTask(e.taskId);
        });

    await executor.execute(
      run,
      definition,
      context,
      isCancelled: () => cancelled,
    );
    await sub.cancel();

    // Only step 1 executed before cancellation was detected.
    expect(stepCount, equals(1));
  });

  test('workflow budget exceeded pauses workflow before next step', () async {
    final definition = makeDefinition(
      maxTokens: 1000,
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompt: 'Do step 2'),
      ],
    );

    var run = makeRun(definition);
    // Pre-seed totalTokens to exceed budget.
    run = run.copyWith(totalTokens: 1000);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          stepCount++;
          await completeTask(e.taskId);
        });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Step 1 executes but budget is checked before step 2.
    expect(stepCount, lessThanOrEqualTo(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    expect(finalRun?.errorMessage, contains('budget'));
  });

  test('automatic metadata keys set after step completes', () async {
    final definition = makeDefinition(steps: [
      const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
    ]);

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          await completeTask(e.taskId);
        });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(context['step1.status'], equals('accepted'));
    expect(context['step1.tokenCount'], isNotNull);
  });

  test('WorkflowRunStatusChangedEvent fired on completion', () async {
    final definition = makeDefinition();
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final statusEvents = <WorkflowRunStatusChangedEvent>[];
    final statusSub = eventBus.on<WorkflowRunStatusChangedEvent>().listen(statusEvents.add);

    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          await completeTask(e.taskId);
        });

    await executor.execute(run, definition, context);
    await sub.cancel();
    await statusSub.cancel();

    expect(statusEvents, isNotEmpty);
    expect(statusEvents.last.newStatus, equals(WorkflowRunStatus.completed));
  });

  test('WorkflowStepCompletedEvent fired after each step', () async {
    final definition = makeDefinition(steps: [
      const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
      const WorkflowStep(id: 'step2', name: 'Step 2', prompt: 'Do step 2'),
    ]);
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);

    final sub = eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          await completeTask(e.taskId);
        });

    await executor.execute(run, definition, context);
    await sub.cancel();
    await stepSub.cancel();

    expect(stepEvents.length, equals(2));
    expect(stepEvents[0].stepId, equals('step1'));
    expect(stepEvents[1].stepId, equals('step2'));
  });

  group('retry integration', () {
    test('workflow waits through retry cycle, completes when retry succeeds', () async {
      // maxRetries: 2 so that after first failure (retryCount becomes 1),
      // the condition retryCount(1) < maxRetries(2) is true → workflow keeps waiting.
      final definition = makeDefinition(steps: [
        const WorkflowStep(
          id: 'step1',
          name: 'Step 1',
          prompt: 'Do step 1',
          maxRetries: 2,
        ),
      ]);

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      // Track queued events to distinguish first creation from retry re-queue.
      int queueCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            queueCount++;
            if (queueCount == 1) {
              // First attempt: fail, then simulate _markFailedOrRetry re-queue.
              // Set retryCount: 1 (< maxRetries: 2) so workflow keeps waiting.
              await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
              await taskService.updateFields(e.taskId, retryCount: 1);
              await taskService.transition(e.taskId, TaskStatus.failed, trigger: 'system');
              await taskService.transition(e.taskId, TaskStatus.queued, trigger: 'retry');
            } else {
              // Second attempt (retry): succeed.
              await completeTask(e.taskId);
            }
          });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(queueCount, equals(2)); // queued twice (original + retry)
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow pauses after all retries exhausted', () async {
      // maxRetries: 2 so the first retry is allowed (retryCount 1 < maxRetries 2).
      // Second failure increments retryCount to 2, making retryCount(2) >= maxRetries(2)
      // → permanent failure → workflow pauses.
      final definition = makeDefinition(steps: [
        const WorkflowStep(
          id: 'step1',
          name: 'Step 1',
          prompt: 'Do step 1',
          maxRetries: 2,
        ),
      ]);

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      int queueCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            queueCount++;
            if (queueCount == 1) {
              // First attempt: fail, retryCount → 1 (< maxRetries 2), re-queue.
              await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
              await taskService.updateFields(e.taskId, retryCount: 1);
              await taskService.transition(e.taskId, TaskStatus.failed, trigger: 'system');
              await taskService.transition(e.taskId, TaskStatus.queued, trigger: 'retry');
            } else {
              // Second attempt (retry 1): fail, retryCount → 2 (== maxRetries 2).
              // Executor sees retryCount(2) < maxRetries(2) = false → permanent failure.
              await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
              await taskService.updateFields(e.taskId, retryCount: 2);
              await taskService.transition(e.taskId, TaskStatus.failed, trigger: 'system');
            }
          });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(queueCount, equals(2));
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    });
  });

  test('step timeout pauses workflow', () async {
    const timeoutSeconds = 1;
    final definition = makeDefinition(steps: [
      const WorkflowStep(
        id: 'step1',
        name: 'Step 1',
        prompt: 'Do step 1',
        timeoutSeconds: timeoutSeconds,
      ),
    ]);

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    // Do NOT complete the task — let it time out.
    await executor.execute(run, definition, context);

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    expect(finalRun?.errorMessage, contains('timed out'));
  }, timeout: const Timeout(Duration(seconds: 10)));

  group('budget warning', () {
    test('fires WorkflowBudgetWarningEvent at 80% of maxTokens', () async {
      final definition = makeDefinition(
        maxTokens: 10000,
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompt: 'Do step 2'),
        ],
      );

      // Pre-seed at 80% of budget so warning fires before step 1.
      var run = makeRun(definition);
      run = run.copyWith(totalTokens: 8000);
      await repository.insert(run);
      final context = WorkflowContext();

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            await completeTask(e.taskId);
          });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await warnSub.cancel();

      expect(warnings, hasLength(1));
      expect(warnings.first.consumed, equals(8000));
      expect(warnings.first.limit, equals(10000));
    });

    test('warning fires only once per run (deduplication)', () async {
      final definition = makeDefinition(
        maxTokens: 10000,
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompt: 'Do step 2'),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompt: 'Do step 3'),
        ],
      );

      var run = makeRun(definition);
      run = run.copyWith(totalTokens: 8500);
      await repository.insert(run);
      final context = WorkflowContext();

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            await completeTask(e.taskId);
          });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await warnSub.cancel();

      // Warning fires at the first budget check, not again at subsequent checks.
      expect(warnings, hasLength(1));
    });
  });

  group('parallel group resume', () {
    test('resume re-runs only failed parallel steps', () async {
      final definition = makeDefinition(steps: [
        const WorkflowStep(id: 'pA', name: 'Parallel A', prompt: 'Do A', parallel: true),
        const WorkflowStep(id: 'pB', name: 'Parallel B', prompt: 'Do B', parallel: true),
      ]);

      // Simulate state after a parallel group where pB failed:
      // currentStepIndex = 0 (group start), _parallel.failed.stepIds = ['pB'].
      var run = makeRun(definition, stepIndex: 0);
      run = run.copyWith(
        contextJson: {
          '_parallel.current.stepIds': ['pA', 'pB'],
          '_parallel.failed.stepIds': ['pB'],
          // pA already succeeded — its context is already merged.
          'pA.status': 'accepted',
          'pA.tokenCount': 100,
        },
      );
      await repository.insert(run);
      final context = WorkflowContext.fromJson({
        'pA.status': 'accepted',
        'pA.tokenCount': 100,
      });

      final createdTaskTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            final task = await taskService.get(e.taskId);
            if (task != null) createdTaskTitles.add(task.title);
            await completeTask(e.taskId);
          });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // Only pB should have been re-executed, not pA.
      expect(createdTaskTitles, hasLength(1));
      expect(createdTaskTitles.first, contains('Parallel B'));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('parallel failure keeps currentStepIndex at group start', () async {
      final definition = makeDefinition(steps: [
        const WorkflowStep(id: 'pA', name: 'Parallel A', prompt: 'Do A', parallel: true),
        const WorkflowStep(id: 'pB', name: 'Parallel B', prompt: 'Do B', parallel: true),
        const WorkflowStep(id: 'step3', name: 'Step 3', prompt: 'Do 3'),
      ]);

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            final task = await taskService.get(e.taskId);
            // Fail pB, succeed pA.
            if (task != null && task.title.contains('Parallel B')) {
              await completeTask(e.taskId, status: TaskStatus.failed);
            } else {
              await completeTask(e.taskId);
            }
          });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      // currentStepIndex should be at group start (0), not past the group.
      expect(finalRun?.currentStepIndex, equals(0));
      // Failed step IDs should be persisted.
      final failedIds = finalRun?.contextJson['_parallel.failed.stepIds'] as List?;
      expect(failedIds, equals(['pB']));
    });
  });

  group('loop step resume', () {
    test('resume re-runs from failed loop step, not iteration start', () async {
      final definition = WorkflowDefinition(
        name: 'test-workflow',
        description: 'Test',
        steps: [
          const WorkflowStep(id: 'loopA', name: 'Loop A', prompt: 'Do A'),
          const WorkflowStep(id: 'loopB', name: 'Loop B', prompt: 'Do B'),
        ],
        loops: [
          const WorkflowLoop(
            id: 'loop1',
            steps: ['loopA', 'loopB'],
            maxIterations: 3,
            exitGate: 'loopB.status == accepted',
          ),
        ],
      );

      // Simulate resume state: mid-loop, iteration 1, loopB failed.
      var run = makeRun(definition, stepIndex: 2); // Past linear pass.
      run = run.copyWith(
        contextJson: {
          '_loop.current.id': 'loop1',
          '_loop.current.iteration': 1,
          '_loop.current.stepId': 'loopB',
          // loopA already completed in this iteration.
          'loopA.status': 'accepted',
          'loopA.tokenCount': 50,
        },
      );
      await repository.insert(run);
      final context = WorkflowContext.fromJson({
        'loopA.status': 'accepted',
        'loopA.tokenCount': 50,
      });

      final createdTaskTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            final task = await taskService.get(e.taskId);
            if (task != null) createdTaskTitles.add(task.title);
            await completeTask(e.taskId);
          });

      await executor.execute(
        run,
        definition,
        context,
        startFromStepIndex: 2, // Past linear pass.
        startFromLoopIndex: 0,
        startFromLoopIteration: 1,
        startFromLoopStepId: 'loopB',
      );
      await sub.cancel();

      // Only loopB should have been executed (loopA was skipped).
      // The exit gate passes after loopB succeeds, so loop completes.
      expect(createdTaskTitles, hasLength(1));
      expect(createdTaskTitles.first, contains('Loop B'));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });
}
