import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        OutputConfig,
        OutputFormat,
        StepConfigDefault,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowExecutor,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        WorkflowStep,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, TurnOutcome, TurnStatus;
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

  WorkflowDefinition makeDefinition({List<WorkflowStep>? steps, int? maxTokens, List<WorkflowLoop> loops = const []}) {
    return WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test workflow',
      steps:
          steps ??
          [
            const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
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
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    // Fire completions as tasks are created.
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

  test('context from step 1 is available in step 2 prompt', () async {
    // Step 1 produces output; step 2 uses {{context.research_notes}}.
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Research', prompts: ['Do research'], contextOutputs: ['research_notes']),
        const WorkflowStep(id: 'step2', name: 'Summarize', prompts: ['Summarize: {{context.research_notes}}']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);

    // Pre-create artifact for step 1 to be read during extraction.
    final capturedTaskIds = <String>[];
    final capturedDescriptions = <String>[];

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null) {
        capturedTaskIds.add(e.taskId);
        capturedDescriptions.add(task.description);

        // Create artifact for step 1 to provide context output.
        if (capturedTaskIds.length == 1) {
          final artifactsDir = Directory(p.join(tempDir.path, 'tasks', e.taskId, 'artifacts'));
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

  test('task description includes required output format for explicit json schema', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'review',
          name: 'Review',
          prompts: ['Review the implementation.'],
          outputs: {'result': OutputConfig(format: OutputFormat.json, schema: 'verdict')},
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    String? capturedDescription;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      capturedDescription = task?.description;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(capturedDescription, contains('Review the implementation.'));
    expect(capturedDescription, contains('## Required Output Format'));
    expect(capturedDescription, contains('findings_count'));
  });

  test('workflow task config carries built-in workflow workspace path', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'spec',
          name: 'Generate Spec',
          prompts: ['Write the specification.'],
          outputs: {'result': OutputConfig(format: OutputFormat.json)},
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    String? capturedDescription;
    Map<String, dynamic>? capturedConfigJson;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      capturedDescription = task?.description;
      capturedConfigJson = task?.configJson;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    final workflowWorkspaceDir = p.join(tempDir.path, 'workflow-workspace');
    expect(capturedDescription, contains('Write the specification.'));
    expect(capturedConfigJson?['_workflowWorkspaceDir'], workflowWorkspaceDir);
    expect(File(p.join(workflowWorkspaceDir, 'AGENTS.md')).existsSync(), isTrue);
  });

  test('step failure pauses workflow', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
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
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2'], gate: 'step1.approved == true'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);

    // Context has step1.approved = false → gate will fail.
    // (step1 execution only writes step1.status/tokenCount, not step1.approved)
    final context = WorkflowContext(data: {'step1.approved': 'false'});

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
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

    final executedStepIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
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
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    var cancelled = false;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      cancelled = true; // Signal cancellation after step 1.
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context, isCancelled: () => cancelled);
    await sub.cancel();

    // Only step 1 executed before cancellation was detected.
    expect(stepCount, equals(1));
  });

  test('workflow budget exceeded pauses workflow before next step', () async {
    final definition = makeDefinition(
      maxTokens: 1000,
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    var run = makeRun(definition);
    // Pre-seed totalTokens to exceed budget.
    run = run.copyWith(totalTokens: 1000);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
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
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
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

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
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
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
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
    expect(stepEvents[0].stepId, equals('step1'));
    expect(stepEvents[1].stepId, equals('step2'));
  });

  group('retry integration', () {
    test('workflow waits through retry cycle, completes when retry succeeds', () async {
      // maxRetries: 2 so that after first failure (retryCount becomes 1),
      // the condition retryCount(1) < maxRetries(2) is true → workflow keeps waiting.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], maxRetries: 2),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      // Track queued events to distinguish first creation from retry re-queue.
      int queueCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
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
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], maxRetries: 2),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      int queueCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
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
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], timeoutSeconds: timeoutSeconds),
      ],
    );

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
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      // Pre-seed at 80% of budget so warning fires before step 1.
      var run = makeRun(definition);
      run = run.copyWith(totalTokens: 8000);
      await repository.insert(run);
      final context = WorkflowContext();

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
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
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
        ],
      );

      var run = makeRun(definition);
      run = run.copyWith(totalTokens: 8500);
      await repository.insert(run);
      final context = WorkflowContext();

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
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
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'pA', name: 'Parallel A', prompts: ['Do A'], parallel: true),
          const WorkflowStep(id: 'pB', name: 'Parallel B', prompts: ['Do B'], parallel: true),
        ],
      );

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
      final context = WorkflowContext.fromJson({'pA.status': 'accepted', 'pA.tokenCount': 100});

      final createdTaskTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
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
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'pA', name: 'Parallel A', prompts: ['Do A'], parallel: true),
          const WorkflowStep(id: 'pB', name: 'Parallel B', prompts: ['Do B'], parallel: true),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do 3']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
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

    test('parallel bash steps execute through shared hybrid dispatcher without creating tasks', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash-a', name: 'Bash A', type: 'bash', prompts: ['printf A'], parallel: true),
          const WorkflowStep(id: 'bash-b', name: 'Bash B', type: 'bash', prompts: ['printf B'], parallel: true),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final allTasks = await taskService.list();
      expect(allTasks, isEmpty, reason: 'parallel bash steps should remain zero-task');

      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['bash-a.status'], equals('success'));
      expect(contextData?['bash-b.status'], equals('success'));
    });
  });

  group('loop step resume', () {
    test('resume re-runs from failed loop step, not iteration start', () async {
      final definition = WorkflowDefinition(
        name: 'test-workflow',
        description: 'Test',
        steps: [
          const WorkflowStep(id: 'loopA', name: 'Loop A', prompts: ['Do A']),
          const WorkflowStep(id: 'loopB', name: 'Loop B', prompts: ['Do B']),
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
      final context = WorkflowContext.fromJson({'loopA.status': 'accepted', 'loopA.tokenCount': 50});

      final createdTaskTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
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

  group('multi-prompt execution (S02)', () {
    // Valid UUID session IDs (required by MessageService).
    const sessionMp = '550e8400-e29b-41d4-a716-446655440001';
    const sessionFail = '550e8400-e29b-41d4-a716-446655440002';
    const sessionBudget = '550e8400-e29b-41d4-a716-446655440003';
    const sessionSingle = '550e8400-e29b-41d4-a716-446655440004';

    // Creates a WorkflowExecutor with turn infrastructure wired in.
    WorkflowExecutor makeMultiPromptExecutor(FakeTurnManager fakeTurns) {
      return WorkflowExecutor(
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
        messageService: messageService,
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: fakeTurns.reserveTurn,
          executeTurn: fakeTurns.executeTurn,
          waitForOutcome: (sessionId, turnId) async {
            final outcome = await fakeTurns.waitForOutcome(sessionId, turnId);
            return WorkflowTurnOutcome(status: outcome.status.name);
          },
          availableRunnerCount: () => fakeTurns.availableRunnerCount,
        ),
      );
    }

    // Creates the session directory required by MessageService.insertMessage.
    void createSessionDir(String sessionId) {
      Directory(p.join(sessionsDir, sessionId)).createSync(recursive: true);
    }

    // Writes a session_cost KV entry so _readStepTokenCount returns a non-zero value.
    Future<void> seedSessionCost(String sessionId, int totalTokens) async {
      await kvService.set('session_cost:$sessionId', jsonEncode({'total_tokens': totalTokens}));
    }

    // Listener that accepts a task and assigns it the given sessionId.
    StreamSubscription<TaskStatusChangedEvent> autoAcceptWithSession(String sessionId) {
      return eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        await taskService.updateFields(e.taskId, sessionId: sessionId);
        await completeTask(e.taskId);
      });
    }

    test('3-prompt step: 1 task created + 2 follow-up turns on same session', () async {
      createSessionDir(sessionMp);
      final fakeTurns = FakeTurnManager(
        onWaitForOutcome: (sid, turnId) async =>
            TurnOutcome(turnId: turnId, sessionId: sid, status: TurnStatus.completed, completedAt: DateTime.now()),
      );
      final mpExecutor = makeMultiPromptExecutor(fakeTurns);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First prompt', 'Second prompt', 'Third prompt']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final sub = autoAcceptWithSession(sessionMp);

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // 2 follow-up turns reserved (prompts 2 and 3).
      expect(fakeTurns.reserveTurnCallCount, equals(2));
      expect(fakeTurns.reservedTurns.map((r) => r.sessionId), everyElement(sessionMp));

      // 2 follow-up turns executed, all as continuations (resume: true).
      expect(fakeTurns.executeTurnCallCount, equals(2));
      expect(fakeTurns.executedTurns[0].resume, isTrue);
      expect(fakeTurns.executedTurns[1].resume, isTrue);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('follow-up turn failure causes step to fail and pauses workflow', () async {
      createSessionDir(sessionFail);
      final fakeTurns = FakeTurnManager(
        onWaitForOutcome: (sid, turnId) async {
          // First follow-up (prompt 2) fails; prompt 3 is never reached.
          return TurnOutcome(
            turnId: turnId,
            sessionId: sid,
            status: TurnStatus.failed,
            errorMessage: 'agent crashed',
            completedAt: DateTime.now(),
          );
        },
      );
      final mpExecutor = makeMultiPromptExecutor(fakeTurns);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Prompt one', 'Prompt two (will fail)', 'Prompt three (skipped)'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final sub = autoAcceptWithSession(sessionFail);

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // Only 1 follow-up turn was attempted (failed immediately, prompt 3 skipped).
      expect(fakeTurns.executeTurnCallCount, equals(1));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    });

    test('step budget exceeded before follow-up pauses workflow', () async {
      createSessionDir(sessionBudget);
      final fakeTurns = FakeTurnManager(
        onWaitForOutcome: (sid, turnId) async =>
            TurnOutcome(turnId: turnId, sessionId: sid, status: TurnStatus.completed, completedAt: DateTime.now()),
      );
      final mpExecutor = makeMultiPromptExecutor(fakeTurns);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['First', 'Second'],
            maxTokens: 100, // budget cap
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      // Pre-seed session tokens at or above budget so the check fails before prompt 2.
      await seedSessionCost(sessionBudget, 100);

      final sub = autoAcceptWithSession(sessionBudget);
      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // No follow-up turns attempted — budget exceeded before prompt 2.
      expect(fakeTurns.executeTurnCallCount, equals(0));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      expect(finalRun?.errorMessage, contains('budget exceeded'));
    });

    test('single-prompt step creates no follow-up turns', () async {
      createSessionDir(sessionSingle);
      final fakeTurns = FakeTurnManager(
        onWaitForOutcome: (sid, turnId) async =>
            TurnOutcome(turnId: turnId, sessionId: sid, status: TurnStatus.completed, completedAt: DateTime.now()),
      );
      final mpExecutor = makeMultiPromptExecutor(fakeTurns);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final sub = autoAcceptWithSession(sessionSingle);

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // No follow-up turns.
      expect(fakeTurns.reserveTurnCallCount, equals(0));
      expect(fakeTurns.executeTurnCallCount, equals(0));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('without turn infrastructure, multi-prompt step still completes (graceful degradation)', () async {
      // Executor with no turnManager/messageService — no session dir needed.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First', 'Second']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      // Use the basic executor (no turn infrastructure).
      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // Step still completes — follow-ups are skipped with a warning.
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  // ── S03: Step config defaults integration tests ──────────────────────────────

  group('S03: step config defaults', () {
    WorkflowRun makeS03Run(WorkflowDefinition definition) {
      final now = DateTime.now();
      return WorkflowRun(
        id: 'run-s03',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        currentStepIndex: 0,
        definitionJson: definition.toJson(),
      );
    }

    Future<void> completeS03Task(String taskId) async {
      try {
        await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        /* already running */
      }
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        /* may skip review */
      }
      await taskService.transition(taskId, TaskStatus.accepted, trigger: 'test');
    }

    test('step inherits model from matching stepDefaults', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      Map<String, dynamic>? capturedConfig;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(capturedConfig, isNotNull);
      expect(capturedConfig!['model'], equals('claude-opus-4'));
    });

    test('per-step explicit provider overrides stepDefaults provider', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p'], provider: 'explicit-provider'),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', provider: 'default-provider')],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      String? capturedProvider;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedProvider = task?.provider;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(capturedProvider, equals('explicit-provider'));
    });

    test('first-match-wins: review-code matches review* not catch-all *', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [
          StepConfigDefault(match: 'review*', model: 'opus'),
          StepConfigDefault(match: '*', model: 'sonnet'),
        ],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      Map<String, dynamic>? capturedConfig;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(capturedConfig!['model'], equals('opus'));
    });

    test('no matching default: step uses own config only', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'custom-step', name: 'Custom Step', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'opus')],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      Map<String, dynamic>? capturedConfig;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // No model should be in the config since custom-step doesn't match review*.
      expect(capturedConfig!.containsKey('model'), isFalse);
    });

    test('no stepDefaults on definition: existing behavior unchanged', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(taskCount, equals(1));
      final finalRun = await repository.getById('run-s03');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  // ---------------------------------------------------------------------------
  // S02 (0.16.1): Bash step execution + onError policy
  // ---------------------------------------------------------------------------
  group('S02 (0.16.1): bash step execution', () {
    test('bash step runs command and completes with zero tokens and no task', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['echo hello']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) {
        taskIds.add(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // No task created for bash step.
      expect(taskIds, isEmpty);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      // Zero tokens accumulated.
      expect(finalRun?.totalTokens, equals(0));
    });

    test('bash step sets status=success and exitCode=0 in context', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['echo ok']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      expect(context['bash1.exitCode'], equals(0));
      expect(context['bash1.tokenCount'], equals(0));
    });

    test('bash step extracts text output to context key', () async {
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['printf "captured output"'],
            contextOutputs: const ['bash1.out'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      expect(context['bash1.out'], equals('captured output'));
    });

    test('bash step extracts json output from stdout', () async {
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['printf \'{"key":"value"}\''],
            contextOutputs: const ['result'],
            outputs: const {'result': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final result = context['result'];
      expect(result, isA<Map<String, dynamic>>());
      expect((result as Map<String, dynamic>)['key'], equals('value'));
    });

    test('bash step extracts lines output from stdout', () async {
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['printf "a\\nb\\nc"'],
            contextOutputs: const ['lines'],
            outputs: const {'lines': OutputConfig(format: OutputFormat.lines)},
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final lines = context['lines'];
      expect(lines, isA<List<String>>());
      expect(lines as List<String>, containsAll(['a', 'b', 'c']));
    });

    test('bash step with non-zero exit pauses workflow by default', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['exit 1']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    });

    test('bash step with onError: continue records failure and proceeds', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['exit 42'], onError: 'continue'),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['bash1.status'], equals('failed'));
    });

    test('bash step uses workdir from context when template-referenced', () async {
      // Use tempDir.path as workdir.
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['pwd'],
            workdir: tempDir.path,
            contextOutputs: const ['cwd'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      // pwd output is in context; resolve symlinks for macOS /private/var consistency.
      final expected = tempDir.resolveSymbolicLinksSync();
      expect((context['cwd'] as String?)?.trim(), equals(expected));
    });

    test('bash step with non-existent workdir pauses workflow', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: ['echo x'],
            workdir: '/non/existent/dir/12345',
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    });

    test('bash step timeout pauses workflow', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['sleep 10'], timeoutSeconds: 1),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('bash step timeout terminates the spawned process', () async {
      final outputFile = p.join(tempDir.path, 'timed-out.txt');
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: ['sleep 2; echo late > "$outputFile"'],
            timeoutSeconds: 1,
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      await executor.execute(run, definition, WorkflowContext());
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(File(outputFile).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('bash step with json output fails on empty stdout', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: ['printf ""'],
            contextOutputs: ['result'],
            outputs: {'result': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      await executor.execute(run, definition, WorkflowContext());

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    });

    test('bash step shell-escapes context values', () async {
      // Without escaping, the value "; echo INJECTED" would split the command
      // and produce two separate outputs: the first echo result and then "INJECTED".
      // With proper escaping, the entire value is treated as a literal argument.
      //
      // We test this by checking that a marker word only appears as part of the
      // literal value (i.e. the shell did NOT execute it as a second command).
      // Command: echo SAFE <escaped-value>
      // With injection: outputs "SAFE" then "INJECTED" on a new line.
      // With escaping: outputs "SAFE ; echo INJECTED" on a single line.
      const maliciousValue = '; echo INJECTED';
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['echo SAFE {{context.val}}'],
            contextOutputs: const ['out'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['val'] = maliciousValue;

      await executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      final out = (context['out'] as String?) ?? '';
      // Injection would produce a line containing just "INJECTED" (as separate command output).
      // Escaping produces "SAFE ; echo INJECTED" — the marker appears only on the SAFE line.
      final lines = out.trim().split('\n');
      expect(lines, isNot(contains('INJECTED')), reason: 'injection should not execute as separate command');
      // The first (and only) line contains SAFE and the literal value.
      expect(lines.first, contains('SAFE'));
      expect(lines.first, contains('INJECTED'));
    });
  });

  group('S02 (0.16.1): onError: continue for agent steps', () {
    test('agent step with onError: continue proceeds past failure', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], onError: 'continue'),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      int taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        if (taskCount == 1) {
          // Fail first step.
          await completeTask(e.taskId, status: TaskStatus.failed);
        } else {
          await completeTask(e.taskId);
        }
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(taskCount, equals(2));
      expect(context['step1.status'], equals('failed'));
    });

    test('agent step without onError pauses on failure (backward compat)', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      int taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeTask(e.taskId, status: TaskStatus.failed);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      // Only one task created — second step not reached.
      expect(taskCount, equals(1));
    });
  });

  group('S03 (0.16.1): approval step execution', () {
    test('approval step pauses with zero task creation and zero token increment', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Review Gate', type: 'approval', prompts: ['Please review']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final eventSub = eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);

      await executor.execute(run, definition, context);
      await eventSub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      expect(finalRun?.totalTokens, equals(0));
      // No child tasks created.
      final allTasks = await taskService.list();
      expect(allTasks.where((t) => t.workflowRunId == 'run-1'), isEmpty);

      // Approval metadata in in-memory context (mirrors what's persisted to disk).
      expect(context['gate.approval.status'], equals('pending'));
      expect(context['gate.approval.message'], equals('Please review'));
      expect(context['gate.approval.requested_at'], isNotNull);
      expect(context['gate.tokenCount'], equals(0));

      // SSE event fired.
      expect(approvalEvents, hasLength(1));
      expect(approvalEvents.first.stepId, equals('gate'));
      expect(approvalEvents.first.message, equals('Please review'));
    });

    test('approval step without timeoutSeconds waits indefinitely (no auto-cancel)', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', prompts: ['Approve?']),
        ],
      );
      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      // Wait briefly — no timeout should fire.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      // No timeout deadline persisted.
      expect(context['gate.approval.timeout_deadline'], isNull);
    });

    test('approval step with timeoutSeconds auto-cancels after timeout', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', prompts: ['Approve?'], timeoutSeconds: 1),
        ],
      );
      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      // Run should be paused first; timeout_deadline persisted as flat contextJson key.
      final pausedRun = await repository.getById('run-1');
      expect(pausedRun?.status, equals(WorkflowRunStatus.paused));
      expect(pausedRun?.contextJson['gate.approval.timeout_deadline'], isNotNull);

      // Wait for the timer to fire (1s + buffer).
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      final cancelledRun = await repository.getById('run-1');
      expect(cancelledRun?.status, equals(WorkflowRunStatus.cancelled));
      expect(cancelledRun?.contextJson['gate.approval.cancel_reason'], equals('timeout'));
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('approval step resolves prompt template from context', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'gate',
            name: 'Gate',
            type: 'approval',
            prompts: ['Review result: {{context.prior_output}}'],
          ),
        ],
      );
      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();
      context['prior_output'] = 'all tests pass';

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.contextJson['gate.approval.message'], equals('Review result: all tests pass'));
    });
  });

  // ── S04 (0.16.1): continueSession runtime + delta accounting ─────────────────

  group('S04 (0.16.1): continueSession runtime', () {
    const sessionStep1 = '550e8400-e29b-41d4-a716-446655440101';

    void createSessionDir(String sessionId) {
      Directory(p.join(sessionsDir, sessionId)).createSync(recursive: true);
    }

    Future<void> seedSessionCost(String sessionId, int totalTokens) async {
      await kvService.set('session_cost:$sessionId', jsonEncode({'total_tokens': totalTokens}));
    }

    test('continued step receives _continueSessionId from preceding step', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Investigate', prompts: ['Investigate the bug']),
          const WorkflowStep(id: 'step2', name: 'Fix', prompts: ['Fix the bug'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var step1TaskId = '';
      var step2TaskId = '';
      final createdTasks = <Task>[];

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final allTasks = await taskService.list();
        final task = allTasks.firstWhere((t) => t.id == e.taskId);
        createdTasks.add(task);

        if (step1TaskId.isEmpty) {
          step1TaskId = e.taskId;
          // Assign session to step 1 (simulates TaskExecutor).
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        } else {
          step2TaskId = e.taskId;
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(step2TaskId, isNotEmpty, reason: 'step 2 task should have been created');

      final step2Task = await taskService.get(step2TaskId);
      expect(
        step2Task?.configJson['_continueSessionId'],
        equals(sessionStep1),
        reason: 'step 2 should inherit step 1 session ID',
      );
    });

    test('continued step resolves root session from an explicit earlier step reference', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Investigate', prompts: ['Investigate the bug']),
          const WorkflowStep(id: 'step2', name: 'Summarize', prompts: ['Summarize findings'], continueSession: 'step1'),
          const WorkflowStep(id: 'step3', name: 'Fix', prompts: ['Fix the bug'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      var createdCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        createdCount++;
        if (createdCount == 1) {
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final allTasks = await taskService.list();
      final step3Task = allTasks.firstWhere((t) => t.stepIndex == 2);
      expect(step3Task.configJson['_continueSessionId'], equals(sessionStep1));
    });

    test('continued step stores baseline tokens in _sessionBaselineTokens', () async {
      createSessionDir(sessionStep1);
      await seedSessionCost(sessionStep1, 250);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Research', prompts: ['Research the problem']),
          const WorkflowStep(id: 'step2', name: 'Implement', prompts: ['Implement fix'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var step1Done = false;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (!step1Done) {
          step1Done = true;
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final allTasks = await taskService.list();
      final step2Task = allTasks.firstWhere(
        (t) => t.workflowRunId == 'run-1' && t.configJson['_continueSessionId'] != null,
      );
      expect(
        step2Task.configJson['_sessionBaselineTokens'],
        equals(250),
        reason: 'baseline should be the token count at step 1 completion',
      );
    });

    test('workflow totals reflect delta not cumulative shared-session tokens', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var step1Done = false;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (!step1Done) {
          step1Done = true;
          // Step 1 uses 150 tokens.
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 150);
        } else {
          // After step 2, shared session has 300 total — delta should be 300 - 150 = 150.
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 300);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      // Workflow total = 150 (step1 fresh) + 150 (step2 delta) = 300.
      // NOT 150 + 300 (full cumulative) = 450.
      expect(finalRun?.totalTokens, equals(300));
    });

    test('continueSession step pauses when previous step has no session ID', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      // Complete step 1 without assigning a session ID.
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      // step 1 completes; step 2 cannot resolve session → workflow pauses.
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      expect(finalRun?.errorMessage, contains('continueSession'));
    });

    test('fresh-session step after continueSession step is unaffected', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Third']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var stepCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        stepCount++;
        if (stepCount == 1) {
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // All 3 steps complete.
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));

      // Step 3 has no _continueSessionId.
      final allTasks = await taskService.list();
      final step3Task = allTasks.where((t) => t.workflowRunId == 'run-1' && t.stepIndex == 2).firstOrNull;
      expect(step3Task?.configJson['_continueSessionId'], isNull);
    });
  });

  // ── S04 G3 (0.16.1): worktree context bridge ─────────────────────────────────

  group('S04 (0.16.1): worktree context bridge', () {
    test('coding step with worktreeJson exposes branch and worktree_path to context', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'fix', name: 'Fix Bug', type: 'coding', prompts: ['Fix the bug']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        // Simulate TaskExecutor persisting worktreeJson on the coding task.
        await taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'branch': 'feat/fix-issue-42',
            'path': '/worktrees/fix-issue-42',
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
        );
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));

      // Auto-exposed keys in contextJson.data (context.toJson() wraps data under 'data').
      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['fix.branch'], equals('feat/fix-issue-42'));
      expect(contextData?['fix.worktree_path'], equals('/worktrees/fix-issue-42'));
    });

    test('coding step without worktreeJson exposes empty values and does not fail workflow', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'fix', name: 'Fix Bug', type: 'coding', prompts: ['Fix the bug']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        // No worktreeJson set — simulates a coding task without worktree (e.g. no project).
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final contextData2 = finalRun?.contextJson['data'] as Map?;
      expect(contextData2?['fix.branch'], equals(''));
      expect(contextData2?['fix.worktree_path'], equals(''));
    });

    test('non-coding step does not inject branch/worktree_path keys', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'research', name: 'Research', prompts: ['Research the issue']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      final contextData3 = finalRun?.contextJson['data'] as Map?;
      expect(contextData3?.containsKey('research.branch'), isFalse);
      expect(contextData3?.containsKey('research.worktree_path'), isFalse);
    });
  });
}
