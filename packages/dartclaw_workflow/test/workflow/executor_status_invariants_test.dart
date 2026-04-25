// WorkflowExecutor status invariants: ADR-022 terminal-status semantics and
// foreach/map fidelity and recovery.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRunStatus,
        WorkflowStep;
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

  group('foreach/map wrapped story_specs fidelity and recovery', () {
    test('wrapped {items:[...]} story_specs are auto-unwrapped and iterated as individual records', () async {
      // FOREACH-RECOVERY: the foreach/map controller must accept wrapped `{items:[...]}`
      // shaped records (as emitted by andthen-plan) and dispatch one child task per item.
      final definition = WorkflowDefinition(
        name: 'foreach-fidelity',
        description: 'foreach fidelity test',
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['implement story {{map.item.id}}'],
            mapOver: 'story_specs',
            maxParallel: 1,
          ),
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

    test('failed map item sets run to failed and preserves cursor at map step', () async {
      // FOREACH-RECOVERY: when a child map item fails, the foreach controller must stop
      // and leave currentStepIndex at or before the map step so a retry can resume.
      final definition = WorkflowDefinition(
        name: 'foreach-recovery',
        description: 'foreach recovery cursor test',
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['implement story'],
            mapOver: 'story_specs',
            maxParallel: 1,
          ),
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
      expect(updateStateDispatched, isFalse, reason: 'update-state must not execute when a map item fails');
      expect(finalRun?.currentStepIndex, equals(0));
    });
  });
}
