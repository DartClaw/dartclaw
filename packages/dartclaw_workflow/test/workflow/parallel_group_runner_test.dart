// Focused component tests for parallel group runner behavior.
// The existing parallel_group_test.dart covers the full happy-path matrix;
// these tests are additive for fast regression localization.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ParallelGroupCompletedEvent,
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

  test('empty parallel group (single non-parallel step) runs sequentially', () async {
    final definition = h.makeDefinition(
      steps: [const WorkflowStep(id: 's1', name: 'S1', prompts: ['p'])],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('single parallel-tagged step runs like a group of one', () async {
    final definition = h.makeDefinition(
      steps: [const WorkflowStep(id: 's1', name: 'S1', prompts: ['p'], parallel: true)],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('parallel group: all 3 steps execute (task count = 3)', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['p'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['p'], parallel: true),
        const WorkflowStep(id: 'p3', name: 'P3', prompts: ['p'], parallel: true),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    expect(taskCount, equals(3));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('parallel group failure: one step fails, workflow pauses', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['p'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['p'], parallel: true),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      // First task fails, second succeeds.
      await h.completeTask(e.taskId, status: taskCount == 1 ? TaskStatus.failed : TaskStatus.accepted);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('ParallelGroupCompletedEvent fired once for each group', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['p'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['p'], parallel: true),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final groupEvents = <ParallelGroupCompletedEvent>[];
    final groupSub = h.eventBus.on<ParallelGroupCompletedEvent>().listen(groupEvents.add);

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();
    await groupSub.cancel();

    expect(groupEvents, hasLength(1));
    expect(groupEvents.first.stepIds, containsAll(['p1', 'p2']));
    expect(groupEvents.first.successCount, equals(2));
    expect(groupEvents.first.failureCount, equals(0));
  });

  test('cancellation between parallel and sequential step stops execution', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['p'], parallel: true),
        const WorkflowStep(id: 'after', name: 'After', prompts: ['p']),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    var cancelled = false;
    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      cancelled = true;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext(), isCancelled: () => cancelled);
    await sub.cancel();

    // Only the parallel step executed; 'after' was stopped by cancellation.
    expect(taskCount, lessThanOrEqualTo(1));
  });
}
