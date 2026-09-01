// WorkflowExecutor status invariants: ADR-022 terminal-status semantics and
// foreach/map fidelity and recovery.
@Tags(['component'])
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show TaskStatus, TaskStatusChangedEvent, WorkflowContext, WorkflowDefinition, WorkflowStep, WorkflowTaskType;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('ADR-022 status transitions', () {
    test('terminal getter is true only for completed, failed, and cancelled', () {
      // Proves ADR-022: exactly three terminal states.
      expect(WorkflowRunStatus.completed.terminal, isTrue);
      expect(WorkflowRunStatus.failed.terminal, isTrue);
      expect(WorkflowRunStatus.cancelled.terminal, isTrue);
      expect(WorkflowRunStatus.running.terminal, isFalse);
      expect(WorkflowRunStatus.pending.terminal, isFalse);
      expect(WorkflowRunStatus.paused.terminal, isFalse);
      expect(WorkflowRunStatus.awaitingApproval.terminal, isFalse);
    });

    test('only failed status has terminal=true among non-completed/cancelled states', () {
      // Proves ADR-022 status semantics: running and paused are non-terminal;
      // failed is terminal (enabling the retry-from-failed guard in WorkflowService).
      expect(WorkflowRunStatus.running.terminal, isFalse);
      expect(WorkflowRunStatus.paused.terminal, isFalse);
      expect(WorkflowRunStatus.awaitingApproval.terminal, isFalse);
      expect(WorkflowRunStatus.failed.terminal, isTrue);
    });
  });

  group('retired map controller', () {
    test('a resumed run whose step declares map_over without per-item steps fails loud', () async {
      // A run persisted before the map controller was removed re-normalizes its
      // retired controller into an action node. Running it would send the
      // controller prompt once instead of fanning out.
      const definition = WorkflowDefinition(
        name: 'legacy-map',
        description: 'legacy map run',
        steps: [
          WorkflowStep(id: 'fanout', name: 'Fanout', prompts: ['Process {{map.item}}'], mapOver: 'items'),
        ],
      );
      // `parallel: true` normalizes the same step into a parallel group instead
      // of an action node; the pre-dispatch check must refuse both.
      final parallelVariant = WorkflowDefinition(
        name: definition.name,
        description: definition.description,
        steps: const [
          WorkflowStep(
            id: 'fanout',
            name: 'Fanout',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            parallel: true,
          ),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);

      var dispatched = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        dispatched++;
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(
        run,
        definition,
        WorkflowContext(
          data: {
            'items': ['a', 'b', 'c'],
          },
        ),
      );

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('foreach_steps'));
      expect(dispatched, isZero, reason: 'the retired controller must not run its own prompt once');

      final parallelRun = h.makeRun(parallelVariant).copyWith(id: 'run-2');
      await h.repository.insert(parallelRun);
      await h.executor.execute(
        parallelRun,
        parallelVariant,
        WorkflowContext(
          data: {
            'items': ['a'],
          },
        ),
      );
      await sub.cancel();

      final finalParallelRun = await h.repository.getById('run-2');
      expect(finalParallelRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalParallelRun?.errorMessage, contains('foreach_steps'));
      expect(dispatched, isZero, reason: 'the parallel-group arm must refuse it too');
    });
  });

  group('foreach wrapped story_specs fidelity and recovery', () {
    test('wrapped {items:[...]} story_specs are auto-unwrapped and iterated as individual records', () async {
      // FOREACH-RECOVERY: the foreach controller must accept wrapped `{items:[...]}`
      // shaped records (as emitted by dartclaw-plan) and dispatch one child task per item.
      final definition = WorkflowDefinition(
        name: 'foreach-fidelity',
        description: 'foreach fidelity test',
        steps: const [
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'story_specs',
            maxParallel: 1,
            foreachSteps: ['implement'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement story {{map.item.id}}']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      const wrappedStorySpecs = {
        'items': [
          {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
          {
            'id': 'S02',
            'title': 'Story Two',
            'dependencies': ['S01'],
            'spec_path': 'fis/s02.md',
          },
        ],
      };

      var dispatchedCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        dispatchedCount++;
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext(data: {'story_specs': wrappedStorySpecs}));
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(dispatchedCount, equals(2));
    });

    test('failed foreach item sets run to failed and preserves cursor at the controller', () async {
      // FOREACH-RECOVERY: when a child item fails, the foreach controller must stop
      // and leave currentStepIndex at or before the controller so a retry can resume.
      final definition = WorkflowDefinition(
        name: 'foreach-recovery',
        description: 'foreach recovery cursor test',
        steps: const [
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'story_specs',
            maxParallel: 1,
            foreachSteps: ['implement'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement story']),
          WorkflowStep(id: 'update-state', name: 'Update State', prompts: ['update state']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      const storySpecs = {
        'items': [
          {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
          {'id': 'S02', 'title': 'Story Two', 'dependencies': <String>[], 'spec_path': 'fis/s02.md'},
        ],
      };

      var itemIndex = 0;
      var updateStateDispatched = false;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task == null) return;
        if (task.title.contains('Update State')) {
          updateStateDispatched = true;
          await h.completeTask(e.taskId);
        } else {
          if (itemIndex == 1) {
            await h.completeTask(e.taskId, status: TaskStatus.failed);
          } else {
            await h.completeTask(e.taskId);
          }
          itemIndex++;
        }
      });

      await h.executor.execute(run, definition, WorkflowContext(data: {'story_specs': storySpecs}));
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(updateStateDispatched, isFalse, reason: 'update-state must not execute when a foreach item fails');
      expect(finalRun?.currentStepIndex, equals(0));
    });
  });
}
