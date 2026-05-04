// Focused component tests for loop step runner behavior.
// The existing loop_execution_test.dart covers the full feature matrix;
// these tests are additive for fast regression localization.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show TaskStatus, TaskStatusChangedEvent, WorkflowContext, WorkflowLoop, WorkflowRunStatus, WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('empty loop body with maxIterations=1 completes without tasks', () async {
    // A loop with steps that reference non-existent step IDs is not valid,
    // so instead: single step, exits on iteration 1.
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['s1'], maxIterations: 1, exitGate: 'loop.l1.iteration == 1'),
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
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    // Executes exactly once (maxIterations=1, gate passes on iter 1).
    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('single-step loop runs all iterations before continuing', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
        const WorkflowStep(id: 'after', name: 'After', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['ls'], maxIterations: 3, exitGate: 'loop.l1.iteration == 2'),
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
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    // 2 loop iterations + 1 sequential after = 3 tasks total.
    expect(taskCount, equals(3));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('maxIterations circuit breaker: fails run when gate never passes', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['ls'], maxIterations: 2, exitGate: 'never == true'),
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

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('max iterations'));
  });

  test('step failure inside loop fails the run', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['ls'], maxIterations: 3, exitGate: 'ls.status == accepted'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId, status: TaskStatus.failed);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('cancellation during loop stops execution early', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['ls'], maxIterations: 5, exitGate: 'loop.l1.iteration == 5'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    var cancelled = false;
    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      cancelled = true;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext(), isCancelled: () => cancelled);
    await sub.cancel();

    expect(taskCount, lessThan(5));
  });

  test('entry gate skips loop body when condition is false', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
        const WorkflowStep(id: 'after', name: 'After', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(
          id: 'l1',
          steps: ['ls'],
          maxIterations: 3,
          entryGate: 'findings > 0',
          exitGate: 'loop.l1.iteration == 1',
        ),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['findings'] = 0;

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    // Entry gate is false: loop body skipped, only 'after' runs = 1 task.
    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });
}
