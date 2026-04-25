// WorkflowExecutor resume: retry integration, parallel group resume, and
// loop step resume. Tests that the executor can restart mid-run from a
// previously persisted cursor.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnFailurePolicy,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowLoop,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('retry integration', () {
    test('workflow waits through retry cycle, completes when retry succeeds', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], maxRetries: 2),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      int queueCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        queueCount++;
        if (queueCount == 1) {
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          await h.taskService.updateFields(e.taskId, retryCount: 1);
          await h.taskService.transition(e.taskId, TaskStatus.failed, trigger: 'retry-in-progress');
          await h.taskService.transition(e.taskId, TaskStatus.queued, trigger: 'retry');
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      expect(queueCount, equals(2));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow waits through single task retry before applying workflow retry', () async {
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
      final context = WorkflowContext();

      final taskIds = <String>[];
      int queueCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskIds.add(e.taskId);
        queueCount++;
        if (queueCount == 1) {
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          await h.taskService.updateFields(e.taskId, retryCount: 1);
          await h.taskService.transition(e.taskId, TaskStatus.failed, trigger: 'retry-in-progress');
          await h.taskService.transition(e.taskId, TaskStatus.queued, trigger: 'retry');
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      expect(queueCount, equals(2));
      expect(taskIds.toSet(), hasLength(1), reason: 'task-level retry must not spawn a duplicate workflow step task');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow pauses after all retries exhausted', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], maxRetries: 2),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      int queueCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        queueCount++;
        if (queueCount == 1) {
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          await h.taskService.updateFields(e.taskId, retryCount: 1);
          await h.taskService.transition(e.taskId, TaskStatus.failed, trigger: 'retry-in-progress');
          await h.taskService.transition(e.taskId, TaskStatus.queued, trigger: 'retry');
        } else {
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          await h.taskService.updateFields(e.taskId, retryCount: 2);
          await h.taskService.transition(e.taskId, TaskStatus.failed, trigger: 'system');
        }
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      expect(queueCount, equals(2));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });
  });

  group('parallel group resume', () {
    test('resume re-runs only failed steps in the group', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'pA', name: 'Parallel A', prompts: ['Do A'], parallel: true),
          const WorkflowStep(id: 'pB', name: 'Parallel B', prompts: ['Do B'], parallel: true),
        ],
      );

      var run = h.makeRun(definition, stepIndex: 0);
      run = run.copyWith(
        contextJson: {
          '_parallel.current.stepIds': ['pA', 'pB'],
          '_parallel.failed.stepIds': ['pB'],
          'pA.status': 'accepted',
          'pA.tokenCount': 100,
        },
      );
      await h.repository.insert(run);
      final context = WorkflowContext.fromJson({'pA.status': 'accepted', 'pA.tokenCount': 100});

      final createdTaskTitles = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task != null) createdTaskTitles.add(task.title);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      expect(createdTaskTitles, hasLength(1));
      expect(createdTaskTitles.first, contains('Parallel B'));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('group failure keeps currentStepIndex at group start', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'pA', name: 'Parallel A', prompts: ['Do A'], parallel: true),
          const WorkflowStep(id: 'pB', name: 'Parallel B', prompts: ['Do B'], parallel: true),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do 3']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task != null && task.title.contains('Parallel B')) {
          await h.completeTask(e.taskId, status: TaskStatus.failed);
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.currentStepIndex, equals(0));
      final failedIds = finalRun?.contextJson['_parallel.failed.stepIds'] as List?;
      expect(failedIds, equals(['pB']));
    });

    test('hybrid in-process steps execute through shared dispatcher without creating tasks', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash-a', name: 'Bash A', type: 'bash', prompts: ['printf A'], parallel: true),
          const WorkflowStep(id: 'bash-b', name: 'Bash B', type: 'bash', prompts: ['printf B'], parallel: true),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      await h.executor.execute(run, definition, WorkflowContext());

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final allTasks = await h.taskService.list();
      expect(allTasks, isEmpty, reason: 'parallel bash steps should remain zero-task');
      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['bash-a.status'], equals('success'));
      expect(contextData?['bash-b.status'], equals('success'));
    });
  });

  group('loop step resume', () {
    test('resume re-runs from failed in-iteration step, not iteration start', () async {
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

      var run = h.makeRun(definition, stepIndex: 2);
      run = run.copyWith(
        contextJson: {
          '_loop.current.id': 'loop1',
          '_loop.current.iteration': 1,
          '_loop.current.stepId': 'loopB',
          'loopA.status': 'accepted',
          'loopA.tokenCount': 50,
        },
      );
      await h.repository.insert(run);
      final context = WorkflowContext.fromJson({'loopA.status': 'accepted', 'loopA.tokenCount': 50});

      final createdTaskTitles = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task != null) createdTaskTitles.add(task.title);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(
        run,
        definition,
        context,
        startFromStepIndex: 2,
        startFromLoopIndex: 0,
        startFromLoopIteration: 1,
        startFromLoopStepId: 'loopB',
      );
      await sub.cancel();

      expect(createdTaskTitles, hasLength(1));
      expect(createdTaskTitles.first, contains('Loop B'));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('checkpoints iteration cursor after each sibling step so resume can continue in-iteration', () async {
      final definition = WorkflowDefinition(
        name: 'loop-checkpoint',
        description: 'Loop checkpointing',
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

      var run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      var cancelAfterLoopASuccess = false;
      final createdTaskTitlesFirstPass = <String>[];
      final firstPassSub = h.eventBus
          .on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            final task = await h.taskService.get(e.taskId);
            if (task == null) return;
            createdTaskTitlesFirstPass.add(task.title);
            await h.completeTask(e.taskId);
            if (task.title.contains('Loop A')) {
              cancelAfterLoopASuccess = true;
            }
          });

      await h.executor.execute(run, definition, context, isCancelled: () => cancelAfterLoopASuccess);
      await firstPassSub.cancel();

      final interrupted = await h.repository.getById('run-1');
      expect(createdTaskTitlesFirstPass, hasLength(1));
      expect(createdTaskTitlesFirstPass.first, contains('Loop A'));
      expect(interrupted?.contextJson['_loop.current.stepId'], equals('loopB'));
      expect((interrupted?.contextJson['data'] as Map?)?['loopA.status'], equals('accepted'));

      final createdTaskTitlesSecondPass = <String>[];
      final secondPassSub = h.eventBus
          .on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            final task = await h.taskService.get(e.taskId);
            if (task == null) return;
            createdTaskTitlesSecondPass.add(task.title);
            await h.completeTask(e.taskId);
          });

      run = interrupted!;
      await h.executor.execute(
        run,
        definition,
        context,
        startFromStepIndex: 0,
        startFromLoopIndex: 0,
        startFromLoopIteration: 1,
        startFromLoopStepId: interrupted.contextJson['_loop.current.stepId'] as String?,
      );
      await secondPassSub.cancel();

      expect(createdTaskTitlesSecondPass, hasLength(1));
      expect(createdTaskTitlesSecondPass.first, contains('Loop B'));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });
}
