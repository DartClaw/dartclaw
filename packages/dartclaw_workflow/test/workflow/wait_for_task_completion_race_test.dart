// Race fix for _waitForTaskCompletion (TD-082): verifies that abort takes
// priority over simultaneous task completion so the executor exits early
// rather than silently continuing after a run transitions away from running.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('_waitForTaskCompletion abort priority', () {
    test('abort fired before task completion causes executor to exit without completing run', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        // Simulate: abort arrives first, then task completes.
        h.eventBus.fire(
          WorkflowRunStatusChangedEvent(
            runId: run.id,
            definitionName: definition.name,
            oldStatus: WorkflowRunStatus.running,
            newStatus: WorkflowRunStatus.paused,
            timestamp: DateTime.now(),
          ),
        );
        // Allow executor to process the abort before completing the task.
        await Future<void>.delayed(Duration.zero);
        // Guard: executor may have already exited; task ops after that throw.
        try {
          await h.completeTask(e.taskId);
        } catch (_) {
          // DB already closed — acceptable when executor exits early.
        }
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // The executor must exit after the first step due to the abort signal.
      // The run will not advance to step2.
      final tasks = await h.taskService.list();
      expect(tasks.length, 1, reason: 'only step1 should have dispatched a task');
    });

    test('abort wins when fired simultaneously with task completion', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        // Fire abort and complete task in the same microtask batch.
        h.eventBus.fire(
          WorkflowRunStatusChangedEvent(
            runId: run.id,
            definitionName: definition.name,
            oldStatus: WorkflowRunStatus.running,
            newStatus: WorkflowRunStatus.cancelled,
            timestamp: DateTime.now(),
          ),
        );
        try {
          await h.completeTask(e.taskId);
        } catch (_) {
          // DB already closed — acceptable when executor exits early.
        }
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // The executor exits after step1; step2 must not be dispatched.
      final tasks = await h.taskService.list();
      expect(tasks.length, 1, reason: 'abort must prevent step2 from dispatching');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, isNot(equals(WorkflowRunStatus.completed)));
    });
  });
}
