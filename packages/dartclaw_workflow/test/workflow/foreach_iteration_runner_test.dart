// Focused component tests for foreach iteration runner behavior.
// The existing map_step_execution_test.dart covers the full feature matrix;
// these tests are additive for fast regression localization.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show TaskStatus, TaskStatusChangedEvent, WorkflowContext, WorkflowRunStatus, WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('empty collection succeeds with zero tasks', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['p'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = <dynamic>[];

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

    expect(taskCount, equals(0));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('single-item collection spawns exactly one task', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['Process {{map.item}}'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = ['alpha'];

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

    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('3-item collection spawns 3 tasks (sequential by default)', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['Process {{map.item}}'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = ['a', 'b', 'c'];

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

    expect(taskCount, equals(3));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('null mapOver key fails the step cleanly', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['p'], mapOver: 'missing_key'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext(); // 'missing_key' not set

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

    expect(taskCount, equals(0));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('single-item failure fails the run', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['p'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = ['only-item'];

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId, status: TaskStatus.failed);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });
}
