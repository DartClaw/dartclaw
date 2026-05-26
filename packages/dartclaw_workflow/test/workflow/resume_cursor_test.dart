// Resume cursor: verifies that map and foreach steps persist executionCursor
// to WorkflowRun during mid-run checkpointing, and that the cursor is consumed
// correctly on resume so already-completed items are not replayed.
//
// Crash-recovery model: the executor writes executionCursor to the DB after
// every completed iteration. If the server crashes between iterations, the
// next boot reads the cursor from run.executionCursor and resumes from the
// correct position. The tests here verify both the write (mid-iteration
// checkpoint) and the replay-prevention on resume.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskType;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show OutputConfig, WorkflowExecutionCursor, WorkflowExecutionCursorNodeType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        MapIterationCompletedEvent,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('map step cursor', () {
    test('writes executionCursor to DB after each iteration (crash-recovery checkpoint)', () async {
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'ms',
            name: 'Map Step',
            type: WorkflowTaskType.agent,
            mapOver: 'items',
            maxParallel: 1,
            outputs: {'results': OutputConfig()},
          ),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      // Capture the DB state after the first iteration completes.
      WorkflowExecutionCursor? midRunCursor;
      final iterSub = h.eventBus.on<MapIterationCompletedEvent>().where((e) => e.iterationIndex == 0).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        final snap = await h.repository.getById('run-1');
        midRunCursor = snap?.executionCursor;
      });

      final taskSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      final context = WorkflowContext()..['items'] = ['a', 'b', 'c'];
      await h.executor.execute(run, definition, context);
      await Future.wait([iterSub.cancel(), taskSub.cancel()]);

      expect(midRunCursor, isNotNull, reason: 'map step must write executionCursor to DB after each iteration');
      expect(midRunCursor?.nodeType, equals(WorkflowExecutionCursorNodeType.map));
      expect(midRunCursor?.nodeId, equals('ms'));
      expect(midRunCursor?.completedIndices, contains(0));
    });

    test('resumes from executionCursor and replays only incomplete items', () async {
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'ms',
            name: 'Map Step',
            type: WorkflowTaskType.agent,
            mapOver: 'items',
            outputs: {'results': OutputConfig()},
          ),
        ],
      );

      // Seed a cursor with item 0 already completed.
      final seedCursor = WorkflowExecutionCursor.map(
        stepId: 'ms',
        stepIndex: 0,
        totalItems: 3,
        completedIndices: [0],
        resultSlots: [<String, dynamic>{}, null, null],
      );
      final run = h
          .makeRun(definition)
          .copyWith(
            executionCursor: seedCursor,
            contextJson: {
              'items': ['a', 'b', 'c'],
              '_map.current.stepId': 'ms',
              '_map.current.total': 3,
              '_map.current.completedIndices': [0],
              '_map.current.failedIndices': <int>[],
              '_map.current.cancelledIndices': <int>[],
            },
          );
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      final context = WorkflowContext()..['items'] = ['a', 'b', 'c'];
      await h.executor.execute(run, definition, context, startCursor: seedCursor);
      await sub.cancel();

      expect(taskCount, 2, reason: 'completed item 0 must not be replayed');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('foreach step cursor', () {
    test('writes executionCursor to DB after each iteration (crash-recovery checkpoint)', () async {
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            maxParallel: 1,
            foreachSteps: ['child'],
            outputs: {'results': OutputConfig()},
          ),
          const WorkflowStep(id: 'child', name: 'Child', prompts: ['Do item']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      WorkflowExecutionCursor? midRunCursor;
      final iterSub = h.eventBus.on<MapIterationCompletedEvent>().where((e) => e.iterationIndex == 0).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        final snap = await h.repository.getById('run-1');
        midRunCursor = snap?.executionCursor;
      });

      final taskSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      final context = WorkflowContext()..['items'] = ['x', 'y', 'z'];
      await h.executor.execute(run, definition, context);
      await Future.wait([iterSub.cancel(), taskSub.cancel()]);

      expect(midRunCursor, isNotNull, reason: 'foreach step must write executionCursor to DB after each iteration');
      expect(midRunCursor?.nodeType, equals(WorkflowExecutionCursorNodeType.foreach));
      expect(midRunCursor?.nodeId, equals('fe'));
      expect(midRunCursor?.completedIndices, contains(0));
    });

    test('resumes from executionCursor and replays only incomplete foreach items', () async {
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: ['child'],
            outputs: {'results': OutputConfig()},
          ),
          const WorkflowStep(id: 'child', name: 'Child', prompts: ['Do item']),
        ],
      );

      final seedCursor = WorkflowExecutionCursor.foreach(
        stepId: 'fe',
        stepIndex: 0,
        totalItems: 3,
        completedIndices: [0],
        resultSlots: [<String, dynamic>{}, null, null],
      );
      final run = h
          .makeRun(definition)
          .copyWith(
            executionCursor: seedCursor,
            contextJson: {
              'items': ['x', 'y', 'z'],
              '_foreach.current.stepId': 'fe',
              '_foreach.current.total': 3,
              '_foreach.current.completedIndices': [0],
              '_foreach.current.failedIndices': <int>[],
              '_foreach.current.cancelledIndices': <int>[],
            },
          );
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      final context = WorkflowContext()..['items'] = ['x', 'y', 'z'];
      await h.executor.execute(run, definition, context, startCursor: seedCursor);
      await sub.cancel();

      expect(taskCount, 2, reason: 'completed item 0 must not be replayed');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });
}
