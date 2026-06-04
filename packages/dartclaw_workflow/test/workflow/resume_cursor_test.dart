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
        SessionService,
        SessionType,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
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

    test('resumes in-flight foreach iteration at next incomplete child step', () async {
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: ['implement', 'quick-review'],
            outputs: {'results': OutputConfig()},
          ),
          const WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement item'],
            outputs: {'story_result': OutputConfig()},
          ),
          const WorkflowStep(
            id: 'quick-review',
            name: 'Quick Review',
            prompts: ['Review item'],
            inputs: ['story_result'],
            continueSession: 'implement',
          ),
        ],
      );

      final seedCursor = WorkflowExecutionCursor.foreach(
        stepId: 'fe',
        stepIndex: 0,
        totalItems: 2,
        resultSlots: [null, null],
        completedSubStepIdsByIndex: const {
          0: ['implement'],
        },
      );
      final run = h
          .makeRun(definition)
          .copyWith(
            executionCursor: seedCursor,
            contextJson: {
              'items': ['x', 'y'],
              'implement[0].story_result': 'preserved story result',
              'implement[0].sessionId': 'implement-session-0',
              'implement[0].providerSessionId': 'provider-session-0',
              'implement[0].implement.providerSessionId': 'provider-session-0',
              'implement[0].status': 'accepted',
              'implement[0].tokenCount': 1,
              '_foreach.current.stepId': 'fe',
              '_foreach.current.total': 2,
              '_foreach.current.completedIndices': <int>[],
              '_foreach.current.failedIndices': <int>[],
              '_foreach.current.cancelledIndices': <int>[],
              '_foreach.fe.completedSubStepIdsByIndex': {
                '0': ['implement'],
              },
            },
          );
      await h.repository.insert(run);

      var taskCount = 0;
      Task? resumedQuickReviewTask;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task?.stepIndex == 1) {
          final session = await h.sessionService.createSession(type: SessionType.task);
          await h.taskService.updateFields(e.taskId, sessionId: session.id);
        } else {
          resumedQuickReviewTask ??= task;
        }
        await h.completeTask(e.taskId);
      });

      final context = WorkflowContext()
        ..['items'] = ['x', 'y']
        ..['implement[0].story_result'] = 'preserved story result'
        ..['implement[0].sessionId'] = 'implement-session-0'
        ..['implement[0].providerSessionId'] = 'provider-session-0'
        ..['implement[0].implement.providerSessionId'] = 'provider-session-0'
        ..['implement[0].status'] = 'accepted'
        ..['implement[0].tokenCount'] = 1
        ..['_foreach.fe.completedSubStepIdsByIndex'] = {
          '0': ['implement'],
        };
      await h.executor.execute(run, definition, context, startCursor: seedCursor);
      await sub.cancel();

      expect(taskCount, 3, reason: 'implement[0] must be preserved while quick-review[0] and item 1 run');
      expect(resumedQuickReviewTask?.description, contains('preserved story result'));
      expect(resumedQuickReviewTask?.configJson['_continueSessionId'], 'implement-session-0');
      expect(resumedQuickReviewTask?.workflowStepExecution?.providerSessionId, 'provider-session-0');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final results = finalRun?.contextJson['data']?['results'] as List<dynamic>;
      final firstIteration = results.first as Map<Object?, Object?>;
      final restoredImplement = firstIteration['implement'] as Map<Object?, Object?>;
      expect(restoredImplement['story_result'], 'preserved story result');
      expect(restoredImplement, isNot(contains('status')));
      expect(restoredImplement, isNot(contains('tokenCount')));
    });

    test('needsInput hold preserves foreach child cursor without failing iteration', () async {
      final definition = h.makeDefinition(
        steps: [
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: ['implement', 'quick-review', 'simplify'],
            outputs: {'results': OutputConfig()},
          ),
          const WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement item']),
          const WorkflowStep(id: 'quick-review', name: 'Quick Review', prompts: ['Review item']),
          const WorkflowStep(id: 'simplify', name: 'Simplify', prompts: ['Simplify item']),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sessionService = SessionService(baseDir: h.sessionsDir);
      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final approvalSub = h.eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);
      var taskCount = 0;
      final taskSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        if (taskCount == 2) {
          final session = await sessionService.createSession(type: SessionType.task);
          await h.taskService.updateFields(e.taskId, sessionId: session.id);
          await h.messageService.insertMessage(
            sessionId: session.id,
            role: 'assistant',
            content:
                'Blocked pending review approval.\n'
                '<step-outcome>{"outcome":"needsInput","reason":"review needs approval"}</step-outcome>',
          );
        }
        await h.completeTask(e.taskId);
      });

      final context = WorkflowContext()..['items'] = ['x', 'y'];
      await h.executor.execute(run, definition, context);
      await Future.wait([taskSub.cancel(), approvalSub.cancel()]);

      expect(taskCount, 2, reason: 'the hold must stop before simplify[0] or item 1 are dispatched');
      expect(approvalEvents, hasLength(1));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(finalRun?.executionCursor?.completedIndices, isEmpty);
      expect(finalRun?.executionCursor?.failedIndices, isEmpty);
      expect(finalRun?.executionCursor?.completedSubStepIdsByIndex[0], ['implement', 'quick-review']);
      expect(finalRun?.contextJson['_approval.pending.stepId'], 'quick-review');
    });
  });
}
