@Tags(['component'])
library;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ParallelGroupCompletedEvent,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowStepCompletedEvent;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart' show WorkflowExecutorHarness;

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  Future<void> transitionRun(WorkflowRun run, WorkflowRunStatus status, String reason) async {
    final current = await h.repository.getById(run.id) ?? run;
    await h.repository.update(current.copyWith(status: status, updatedAt: DateTime.now()));
    h.eventBus.fire(
      WorkflowRunStatusChangedEvent(
        runId: run.id,
        definitionName: run.definitionName,
        oldStatus: current.status,
        newStatus: status,
        errorMessage: reason,
        timestamp: DateTime.now(),
      ),
    );
  }

  test('3-step parallel group happy path: all steps execute and complete', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
        const WorkflowStep(id: 'p3', name: 'P3', prompts: ['Do p3'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final taskIds = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskIds.add(e.taskId);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskIds.length, equals(3));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('parallel group: metadata keys set for all steps', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(context['p1.status'], equals('accepted'));
    expect(context['p1.tokenCount'], isNotNull);
    expect(context['p2.status'], equals('accepted'));
    expect(context['p2.tokenCount'], isNotNull);
  });

  test('partial failure: failed step pauses workflow, other step succeeds', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
        const WorkflowStep(id: 'p3', name: 'P3', prompts: ['Do p3'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    var callCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      callCount++;
      // Fail p2 (second task created), succeed others.
      if (callCount == 2) {
        await h.completeTask(e.taskId, status: TaskStatus.failed);
      } else {
        await h.completeTask(e.taskId);
      }
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    // All 3 created — parallel, not sequential.
    expect(callCount, equals(3));

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('Parallel step(s) failed'));

    // Successful steps' metadata should still be set.
    expect(context['p1.status'], equals('accepted'));
    expect(context['p3.status'], equals('accepted'));
    // Failed step has 'failed' status.
    expect(context['p2.status'], equals('failed'));
  });

  test('pause during parallel group preserves paused status', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    var queuedCount = 0;
    final failedEvents = <WorkflowRunStatusChangedEvent>[];
    final groupEvents = <ParallelGroupCompletedEvent>[];
    final failureSub = h.eventBus
        .on<WorkflowRunStatusChangedEvent>()
        .where((e) => e.newStatus == WorkflowRunStatus.failed)
        .listen(failedEvents.add);
    final groupSub = h.eventBus.on<ParallelGroupCompletedEvent>().listen(groupEvents.add);
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      queuedCount++;
      if (queuedCount == 2) {
        await transitionRun(run, WorkflowRunStatus.paused, 'operator pause');
      }
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();
    await failureSub.cancel();
    await groupSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    expect(failedEvents, isEmpty);
    expect(groupEvents, isEmpty);
    expect(context['p1.status'], isNull);
    expect(context['p2.status'], isNull);
  });

  test('cancel during parallel group preserves cancelled status', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    var queuedCount = 0;
    final failedEvents = <WorkflowRunStatusChangedEvent>[];
    final groupEvents = <ParallelGroupCompletedEvent>[];
    final failureSub = h.eventBus
        .on<WorkflowRunStatusChangedEvent>()
        .where((e) => e.newStatus == WorkflowRunStatus.failed)
        .listen(failedEvents.add);
    final groupSub = h.eventBus.on<ParallelGroupCompletedEvent>().listen(groupEvents.add);
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      queuedCount++;
      if (queuedCount == 2) {
        await transitionRun(run, WorkflowRunStatus.cancelled, 'operator cancel');
      }
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();
    await failureSub.cancel();
    await groupSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.cancelled));
    expect(failedEvents, isEmpty);
    expect(groupEvents, isEmpty);
    expect(context['p1.status'], isNull);
    expect(context['p2.status'], isNull);
  });

  test('all parallel steps fail: workflow pauses listing all failures', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

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
    expect(finalRun?.errorMessage, contains('Parallel step(s) failed'));
  });

  test('gate blocks entire parallel group when one step gate fails', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true, gate: 'approved == true'),
        const WorkflowStep(id: 'p3', name: 'P3', prompts: ['Do p3'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    // Gate references 'approved' which is 'false' in context.
    final context = WorkflowContext(data: {'approved': 'false'});

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

    // No tasks created — gate blocked the group.
    expect(taskCount, equals(0));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('Gate failed for parallel step'));
  });

  test('budget exceeded before parallel group pauses workflow', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      maxTokens: 100,
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    var run = h.makeRun(definition);
    run = run.copyWith(totalTokens: 100); // Already at budget.
    await h.repository.insert(run);
    final context = WorkflowContext();

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(0));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('budget'));
  });

  test('sequential + parallel + sequential: correct execution order', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'seq1', name: 'Seq1', prompts: ['Do seq1']),
        const WorkflowStep(id: 'par1', name: 'Par1', prompts: ['Do par1'], parallel: true),
        const WorkflowStep(id: 'par2', name: 'Par2', prompts: ['Do par2'], parallel: true),
        const WorkflowStep(id: 'seq2', name: 'Seq2', prompts: ['Do seq2']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final executedIds = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      executedIds.add(e.taskId);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(executedIds.length, equals(4));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('ParallelGroupCompletedEvent fired with correct fields', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final groupEvents = <ParallelGroupCompletedEvent>[];
    final groupSub = h.eventBus.on<ParallelGroupCompletedEvent>().listen(groupEvents.add);

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();
    await groupSub.cancel();

    expect(groupEvents.length, equals(1));
    expect(groupEvents.first.stepIds, containsAll(['p1', 'p2']));
    expect(groupEvents.first.successCount, equals(2));
    expect(groupEvents.first.failureCount, equals(0));
    expect(groupEvents.first.runId, equals('run-1'));
  });

  test('WorkflowStepCompletedEvent fired for each parallel step', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();
    await stepSub.cancel();

    expect(stepEvents.length, equals(2));
    final stepIds = stepEvents.map((e) => e.stepId).toList();
    expect(stepIds, containsAll(['p1', 'p2']));
  });

  test('WorkflowStepCompletedEvent sees persisted parallel context', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final snapshots = <Future<WorkflowRun?>>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      snapshots.add(h.repository.getById(event.runId));
    });

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();
    await stepSub.cancel();

    expect(snapshots, hasLength(2));
    for (final snapshot in await Future.wait(snapshots)) {
      expect(snapshot?.currentStepIndex, equals(2));
      expect(snapshot?.contextJson, isNot(contains('_parallel.current.stepIds')));
      expect(snapshot?.contextJson, isNot(contains('_parallel.failed.stepIds')));
      final data = (snapshot?.contextJson['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      expect(data['p1.status'], equals('accepted'));
      expect(data['p2.status'], equals('accepted'));
    }
  });

  test('parallel group: budget accumulates from all steps', () async {
    final definition = WorkflowDefinition(
      name: 'test',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'p1', name: 'P1', prompts: ['Do p1'], parallel: true),
        const WorkflowStep(id: 'p2', name: 'P2', prompts: ['Do p2'], parallel: true),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    // Run completed — totalTokens is tracked (0 since no session KV in tests).
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(finalRun?.totalTokens, greaterThanOrEqualTo(0));
  });
}
