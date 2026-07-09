// WorkflowExecutor step outcome: step-outcome protocol and onFailure policy
// wiring, and ADR-023 workflow-task boundary contracts.
@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnFailurePolicy,
        SessionService,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show executionEnvelopeMarkerKey, executionEnvelopeOutputsKey, executionEnvelopeVersion;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'package:dartclaw_workflow/src/workflow/step_retry_policy.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('step outcome protocol and onFailure policy wiring', () {
    test('workflow retry failure classifier normalizes comparable failure reasons', () {
      expect(workflowRetryFailureClass(null), 'workflow step failed');
      expect(workflowRetryFailureClass('StateError: Boom (attempt 1)'), 'boom');
      expect(workflowRetryFailureClass('Invalid argument(s): Missing PROJECT [retryable]'), 'missing project');
      expect(workflowRetryFailureClass('x' * 120), hasLength(80));
    });

    Future<void> completeTaskWithOutcome(
      String taskId, {
      required String outcomeContent,
      TaskStatus finalStatus = TaskStatus.accepted,
      int? tokenCount,
    }) async {
      final session = await SessionService(baseDir: h.sessionsDir).createSession(type: SessionType.task);
      await h.taskService.updateFields(taskId, sessionId: session.id);
      if (tokenCount != null) {
        await h.kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': tokenCount}));
      }
      await h.messageService.insertMessage(sessionId: session.id, role: 'assistant', content: outcomeContent);
      await h.completeTask(taskId, status: finalStatus);
    }

    test('emitsOwnOutcome: true omits step-outcome protocol from prompt', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'own-outcome',
            name: 'Own Outcome Step',
            prompts: ['Do the work'],
            emitsOwnOutcome: true,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      String? capturedDescription;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        capturedDescription = task?.description;
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedDescription, isNotNull);
      expect(capturedDescription, isNot(contains('## Step Outcome Protocol')));
      expect(capturedDescription, isNot(contains('<step-outcome>')));
    });

    test('missing step-outcome tag increments workflow.outcome.fallback and emits a warning', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'no-outcome', name: 'No Outcome', prompts: ['Do something']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final logRecords = <LogRecord>[];
      final logSub = Logger.root.onRecord.listen(logRecords.add);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      await logSub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final counterRaw = await h.kvService.get('workflow.outcome.fallback');
      expect(counterRaw, equals('1'));

      final warnings = logRecords.where((r) => r.level >= Level.WARNING).toList();
      expect(
        warnings.any((r) => r.message.contains('Step outcome marker missing') && r.message.contains('no-outcome')),
        isTrue,
        reason: 'Expected a WARNING log naming the step id when <step-outcome> marker is absent',
      );
    });

    test('onFailure: continueWorkflow continues execution after a failed outcome', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.continueWorkflow,
          ),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      int taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        if (taskCount == 1) {
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"failed","reason":"non-blocking failure"}</step-outcome>',
          );
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(2));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('needsInput without onFailure continue moves the run to awaiting approval', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final stepEvents = <WorkflowStepCompletedEvent>[];
      final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);
      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"needsInput","reason":"operator decision required"}</step-outcome>',
          tokenCount: 17,
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      await stepSub.cancel();

      expect(taskCount, equals(1));
      final failedEvent = stepEvents.singleWhere((event) => event.stepId == 'step1');
      expect(failedEvent.success, isFalse);
      expect(failedEvent.outcome, equals('needsInput'));
      expect(failedEvent.reason, equals('operator decision required'));
      expect(failedEvent.tokenCount, equals(17));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
    });

    test('onFailure: continueWorkflow continues execution after a needsInput outcome', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.continueWorkflow,
          ),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        if (taskCount == 1) {
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"needsInput","reason":"optional cleanup blocked"}</step-outcome>',
          );
        } else {
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"continued"}</step-outcome>',
          );
        }
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(2));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('onFailure: retry retries the step when the outcome is failed', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.retry,
            maxRetries: 1,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      int taskCount = 0;
      final descriptions = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        final task = await h.taskService.get(e.taskId);
        descriptions.add(task?.description ?? '');
        if (taskCount == 1) {
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"failed","reason":"first attempt failed"}</step-outcome>',
          );
        } else {
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"fixed"}</step-outcome>',
          );
        }
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(2));
      expect(descriptions.first, isNot(contains('Previous Workflow Attempt')));
      expect(descriptions.last, contains('Previous Workflow Attempt'));
      expect(descriptions.last, contains('first attempt failed'));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('onFailure retry with maxRetries 1 dispatches exactly two workflow tasks on persistent failure', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.retry,
            maxRetries: 1,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskIds.add(e.taskId);
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"failed","reason":"persistent failure $taskIds"}</step-outcome>',
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskIds, hasLength(2));
      for (final taskId in taskIds) {
        expect((await h.taskService.get(taskId))?.maxRetries, equals(0));
      }
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('repeated identical workflow failure class short-circuits before exhausting maxRetries', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.retry,
            maxRetries: 3,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent:
              '<step-outcome>{"outcome":"failed","reason":"Deterministic error: same input"}</step-outcome>',
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(2), reason: 'same failure class should stop before 4 total executions');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('workflow retry exhausts the full budget when failure classes differ', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.retry,
            maxRetries: 3,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent:
              '<step-outcome>{"outcome":"failed","reason":"retry-class-$taskCount: still failing"}</step-outcome>',
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(4), reason: 'maxRetries: 3 permits 4 total attempts without early-stop');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('cancelled task with onFailure: retry dispatches no second attempt and pauses the run', () async {
      // Teardown interruption precedes the retry policy – re-dispatching would
      // start a new task mid-teardown.
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.retry,
            maxRetries: 2,
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await h.completeTask(e.taskId, status: TaskStatus.cancelled);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(1), reason: 'a teardown-cancelled task must not be re-dispatched');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    });

    test('cancelled task with onFailure: continue does not advance past the step', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.continueWorkflow,
          ),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await h.completeTask(e.taskId, status: TaskStatus.cancelled);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(1), reason: 'the next step must not be dispatched after a teardown-cancelled task');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      expect(finalRun?.currentStepIndex, equals(0));
    });

    test('a step-outcome payload claiming cancelled on a succeeded task is ignored', () async {
      // 'cancelled' is engine-derived only: the agent-facing whitelist rejects
      // it, so a spoofed payload falls back to the engine status (succeeded).
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"cancelled","reason":"x"}</step-outcome>',
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(finalRun?.contextJson['data']?['step.step1.outcome'], equals('succeeded'));
    });

    test('a step-outcome payload claiming succeeded on a cancelled task is forced to cancelled', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"all good"}</step-outcome>',
          finalStatus: TaskStatus.cancelled,
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused), reason: 'the step is never treated as success');
      expect(finalRun?.contextJson['data']?['step.step1.outcome'], equals('cancelled'));
    });

    test('a markerless cancelled task does not increment the outcome fallback counter', () async {
      // An expected teardown is not a missing-marker anomaly – the cancelled
      // override returns before the ADR-022 fallback counter/warning path.
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId, status: TaskStatus.cancelled);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.paused));
      expect(await h.kvService.get('workflow.outcome.fallback'), isNull);
    });

    test('single step fails when context extraction throws an unexpected error', () async {
      // Fail loud: an unexpected (non-MissingArtifact, non-StateError) extraction
      // exception must fail the step rather than silently report success with
      // empty/partial outputs. Matches the map path.
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final executor = h.makeExecutor(
        contextExtractor: ThrowingContextExtractor(
          taskService: h.taskService,
          messageService: h.messageService,
          dataDir: h.tempDir.path,
          workflowStepExecutionRepository: h.workflowStepExecutionRepository,
        ),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(
        finalRun?.status,
        equals(WorkflowRunStatus.failed),
        reason: 'an unexpected extraction exception must fail the step, not silently succeed',
      );
    });

    test('step.<id>.outcome and reason are written to context after a successful step-outcome tag', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 's1', name: 'S1', prompts: ['Do step']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"all done"}</step-outcome>',
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(finalRun?.contextJson['data']?['step.s1.outcome'], equals('succeeded'));
      expect(finalRun?.contextJson['data']?['step.s1.outcome.reason'], equals('all done'));
    });
  });

  group('ADR-023 workflow-task boundary', () {
    test('bash step creates zero tasks', () async {
      // Proves ADR-023: host-executed steps do not create Task rows.
      final definition = WorkflowDefinition(
        name: 'bash-zero-task',
        description: 'Bash step boundary',
        steps: const [
          WorkflowStep(id: 'bash1', name: 'Bash', taskType: WorkflowTaskType.bash, prompts: ['echo ok']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      await h.executor.execute(run, definition, WorkflowContext());

      final tasks = await h.taskService.list();
      expect(tasks.where((t) => t.workflowRunId == 'run-1'), isEmpty);
    });

    test('agent step creates exactly one TaskType.coding task', () async {
      // Proves ADR-023: agent steps compile to TaskType.coding tasks.
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'agent1', name: 'Agent', prompts: ['Do work']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final workflowTasks = (await h.taskService.list()).where((t) => t.workflowRunId == 'run-1').toList();
      expect(workflowTasks, hasLength(1));
      expect(workflowTasks.first.type, equals(TaskType.coding));
    });

    test('Task.configJson has no _workflow* keys except the retained token/artifact fields', () async {
      // Proves ADR-023: workflow-owned state stays in WorkflowStepExecution side-table.
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do work']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      String? capturedTaskId;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        capturedTaskId = e.taskId;
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedTaskId, isNotNull);
      final task = await h.taskService.get(capturedTaskId!);
      expect(task, isNotNull);

      final allowedWorkflowKeys = {
        '_workflowInputTokensNew',
        '_workflowCacheReadTokens',
        '_workflowOutputTokens',
        // Host-owned per-step artifacts dir env, exported on every workflow task.
        '_workflowStepArtifactsEnv',
      };
      final forbiddenWorkflowKeys = task!.configJson.keys
          .where((k) => k.startsWith('_workflow') && !allowedWorkflowKeys.contains(k))
          .toList();
      expect(forbiddenWorkflowKeys, isEmpty, reason: 'Found unexpected _workflow* keys: $forbiddenWorkflowKeys');
    });
  });

  group('execution envelope step outcome (TI04)', () {
    Map<String, dynamic> envelope({
      required String outcome,
      String reason = 'because',
      Map<String, dynamic> outputs = const {},
    }) => {
      executionEnvelopeOutputsKey: outputs,
      'step_outcome': {'outcome': outcome, 'reason': reason},
      executionEnvelopeMarkerKey: executionEnvelopeVersion,
    };

    // Runs a single-step workflow, seeding [seedEnvelope] on the finalizer's
    // WorkflowStepExecution and/or attaching [legacyOutcomeContent] before
    // completing the task with [finalStatus].
    Future<dynamic> runStep(
      WorkflowStep step, {
      Map<String, dynamic>? seedEnvelope,
      String? legacyOutcomeContent,
      TaskStatus finalStatus = TaskStatus.accepted,
    }) async {
      final definition = h.makeDefinition(steps: [step]);
      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (seedEnvelope != null) await h.seedExecutionEnvelope(e.taskId, seedEnvelope);
        if (legacyOutcomeContent != null) {
          await h.completeTaskWithOutcome(e.taskId, outcomeContent: legacyOutcomeContent, finalStatus: finalStatus);
        } else {
          await h.completeTask(e.taskId, status: finalStatus);
        }
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      return h.repository.getById('run-1');
    }

    const plainStep = WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']);

    test('resolves succeeded from the execution envelope step_outcome', () async {
      final run = await runStep(
        plainStep,
        seedEnvelope: envelope(outcome: 'succeeded', reason: 'all good'),
      );

      expect(run?.status, equals(WorkflowRunStatus.completed));
      expect(run?.contextJson['data']?['step.step1.outcome'], equals('succeeded'));
      expect(run?.contextJson['data']?['step.step1.outcome.reason'], equals('all good'));
      expect(await h.kvService.get('workflow.outcome.fallback'), isNull);
    });

    test('resolves failed from the execution envelope step_outcome on an accepted task', () async {
      final run = await runStep(
        plainStep,
        seedEnvelope: envelope(outcome: 'failed', reason: 'could not comply'),
      );

      // The task lifecycle is `accepted` (would fall back to succeeded); the run
      // fails only because the envelope's step_outcome was read.
      expect(run?.status, equals(WorkflowRunStatus.failed));
      expect(await h.kvService.get('workflow.outcome.fallback'), isNull);
    });

    test('resolves needsInput from the execution envelope step_outcome and holds for approval', () async {
      final run = await runStep(
        plainStep,
        seedEnvelope: envelope(outcome: 'needsInput', reason: 'human needed'),
      );

      expect(run?.status, equals(WorkflowRunStatus.awaitingApproval));
    });

    test('lifecycle cancellation overrides a succeeded execution envelope outcome', () async {
      final run = await runStep(
        plainStep,
        seedEnvelope: envelope(outcome: 'succeeded', reason: 'all good'),
        finalStatus: TaskStatus.cancelled,
      );

      expect(run?.status, equals(WorkflowRunStatus.paused));
      expect(run?.contextJson['data']?['step.step1.outcome'], equals('cancelled'));
    });

    test('lifecycle failure overrides a succeeded execution envelope outcome', () async {
      final run = await runStep(
        plainStep,
        seedEnvelope: envelope(outcome: 'succeeded', reason: 'all good'),
        finalStatus: TaskStatus.failed,
      );

      expect(run?.status, equals(WorkflowRunStatus.failed));
    });

    test('emitsOwnOutcome step reads the legacy step-outcome tag, not an execution envelope step_outcome', () async {
      // The finalizer envelope carries outputs only (no step_outcome) for
      // emitsOwnOutcome steps; the model-authored tag is the designed channel.
      final run = await runStep(
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do the work'], emitsOwnOutcome: true),
        seedEnvelope: {
          executionEnvelopeOutputsKey: const <String, dynamic>{},
          executionEnvelopeMarkerKey: executionEnvelopeVersion,
        },
        legacyOutcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"self reported"}</step-outcome>',
      );

      expect(run?.status, equals(WorkflowRunStatus.completed));
      expect(run?.contextJson['data']?['step.step1.outcome'], equals('succeeded'));
      expect(await h.kvService.get('workflow.outcome.fallback'), isNull);
    });

    test('missing execution envelope falls back to the legacy step-outcome tag', () async {
      final run = await runStep(
        plainStep,
        legacyOutcomeContent: '<step-outcome>{"outcome":"failed","reason":"legacy path"}</step-outcome>',
      );

      expect(run?.status, equals(WorkflowRunStatus.failed));
      expect(await h.kvService.get('workflow.outcome.fallback'), isNull);
    });

    test('cancellation between the main turn and finalizer yields cancelled with no fallback counter', () async {
      // No envelope was written (the finalizer never ran); a teardown-cancelled
      // task resolves to `cancelled` and never charges the fallback counter.
      final run = await runStep(plainStep, finalStatus: TaskStatus.cancelled);

      expect(run?.status, equals(WorkflowRunStatus.paused));
      expect(run?.contextJson['data']?['step.step1.outcome'], equals('cancelled'));
      expect(await h.kvService.get('workflow.outcome.fallback'), isNull);
    });
  });
}
