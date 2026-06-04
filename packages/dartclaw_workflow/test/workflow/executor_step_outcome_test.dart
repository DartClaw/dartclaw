// WorkflowExecutor step outcome: step-outcome protocol and onFailure policy
// wiring, and ADR-023 workflow-task boundary contracts.
@Tags(['component'])
library;

import 'dart:async';

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
        WorkflowStep;
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
    }) async {
      final session = await SessionService(baseDir: h.sessionsDir).createSession(type: SessionType.task);
      await h.taskService.updateFields(taskId, sessionId: session.id);
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

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"needsInput","reason":"operator decision required"}</step-outcome>',
        );
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(1));
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

    test('S01 onFailure retry with maxRetries 1 dispatches exactly two workflow tasks on persistent failure', () async {
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

    test('S06 repeated identical workflow failure class short-circuits before exhausting maxRetries', () async {
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
          WorkflowStep(id: 'bash1', name: 'Bash', type: WorkflowTaskType.bash, prompts: ['echo ok']),
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

      final allowedWorkflowKeys = {'_workflowInputTokensNew', '_workflowCacheReadTokens', '_workflowOutputTokens'};
      final forbiddenWorkflowKeys = task!.configJson.keys
          .where((k) => k.startsWith('_workflow') && !allowedWorkflowKeys.contains(k))
          .toList();
      expect(forbiddenWorkflowKeys, isEmpty, reason: 'Found unexpected _workflow* keys: $forbiddenWorkflowKeys');
    });
  });
}
