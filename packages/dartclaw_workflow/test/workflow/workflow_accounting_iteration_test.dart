import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show TaskStatus, TaskStatusChangedEvent, WorkflowContext, WorkflowLoop, WorkflowStep, WorkflowTaskType;
import 'package:test/test.dart';

import 'foreach_iteration_runner_test_support.dart';
import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(() async {
    await h.setUp();
  });
  tearDown(h.tearDown);

  test('loop accounting recovery retains the cursor gap and blocks another capped iteration', () async {
    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(id: 'work', name: 'Work', prompts: ['work']),
      ],
      loops: const [
        WorkflowLoop(id: 'repeat', steps: ['work'], maxIterations: 3, exitGate: 'loop.repeat.iteration == 2'),
      ],
    );
    var dispatched = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      dispatched++;
      await h.completeTaskWithOutcome(e.taskId, outcome: 'succeeded', reason: 'settled', tokenCount: null);
    });
    final run = await h.insertRun(definition);
    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    final finalRun = await h.repository.getById(run.id);
    expect(dispatched, 1);
    expect(finalRun?.totalTokens, 0);
    expect(finalRun?.tokenUsageComplete, isFalse);
    expect(finalRun?.status, WorkflowRunStatus.failed);
  });

  test('foreach accounting recovery retains an unavailable child and known lower bound', () async {
    final definition = h.foreachStepDefinition();
    final result = await h.executeQueuedTasks(
      definition,
      h.itemsContext(['first', 'second']),
      completer: (id, count) => h.completeTaskWithOutcome(id, outcome: 'succeeded', tokenCount: count == 1 ? null : 7),
    );

    final data = result.finalRun?.contextJson['data'] as Map<String, dynamic>?;
    expect(result.taskCount, 2);
    expect(data?['process[0].tokenCount'], isNull);
    expect(data?['process[1].tokenCount'], 7);
    expect(data?['map-step.tokenCount'], isNull);
    expect(result.finalRun?.totalTokens, 7);
    expect(result.finalRun?.tokenUsageComplete, isFalse);
  });

  test('parallel accounting recovery stops capped dispatch while settled siblings count once', () async {
    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(id: 'left', name: 'Left', prompts: ['left'], parallel: true),
        WorkflowStep(id: 'right', name: 'Right', prompts: ['right'], parallel: true),
        WorkflowStep(id: 'after', name: 'After', prompts: ['after']),
      ],
    );
    final queued = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      queued.add(task.title);
      await h.completeTaskWithOutcome(
        e.taskId,
        outcome: 'succeeded',
        reason: 'settled',
        tokenCount: task.title.contains('Left') ? null : 11,
      );
    });

    final run = await h.insertRun(definition);
    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    final finalRun = await h.repository.getById(run.id);
    expect(queued, hasLength(2), reason: 'both already-dispatched parallel siblings settle, dependent does not start');
    expect(finalRun?.totalTokens, 11);
    expect(finalRun?.tokenUsageComplete, isFalse);
    expect(finalRun?.status, WorkflowRunStatus.failed);
  });

  test('loop accounting recovery rechecks a settled task after a transient read fault', () async {
    final oldKv = h.kvService;
    final faultingKv = FaultOnceSessionKvService(filePath: oldKv.filePath);
    h.kvService = faultingKv;
    h.executor = h.makeExecutor();
    await oldKv.dispose();
    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(id: 'work', name: 'Work', prompts: ['work']),
      ],
      loops: const [
        WorkflowLoop(id: 'repeat', steps: ['work'], maxIterations: 2, exitGate: 'loop.repeat.iteration == 2'),
      ],
    );
    final run = await h.insertRun(definition);
    var dispatchCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      dispatchCount++;
      await h.completeTaskWithOutcome(e.taskId, outcome: 'succeeded', tokenCount: dispatchCount == 1 ? 9 : 5);
      if (dispatchCount == 1) faultingKv.failNextSessionRead = true;
    });
    addTearDown(sub.cancel);

    await h.executor.execute(run, definition, WorkflowContext());
    final stopped = (await h.repository.getById(run.id))!;
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(stopped.totalTokens, 0);
    expect(dispatchCount, 1);
    expect(stopped.executionCursor?.stepId, '');

    final retry = stopped.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(retry);
    await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
    final completed = (await h.repository.getById(run.id))!;
    expect(dispatchCount, 2, reason: 'the settled first iteration is not dispatched again');
    expect(completed.totalTokens, 14);
    expect(completed.tokenUsageComplete, isTrue);
  });

  test('parallel accounting recovery rechecks one member and counts its settled sibling once', () async {
    final oldKv = h.kvService;
    final faultingKv = FaultOnceSessionKvService(filePath: oldKv.filePath);
    h.kvService = faultingKv;
    h.executor = h.makeExecutor();
    await oldKv.dispose();
    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(id: 'left', name: 'Left', prompts: ['left'], parallel: true),
        WorkflowStep(id: 'right', name: 'Right', prompts: ['right'], parallel: true),
        WorkflowStep(id: 'after', name: 'After', prompts: ['after']),
      ],
    );
    final run = await h.insertRun(definition);
    final queued = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      queued.add(task.title);
      await h.completeTaskWithOutcome(
        e.taskId,
        outcome: 'succeeded',
        tokenCount: task.title.contains('Left') ? 9 : (task.title.contains('Right') ? 11 : 5),
      );
      if (task.title.contains('Left')) {
        faultingKv.failForSessionId = (await h.taskService.get(e.taskId))!.sessionId;
      }
    });
    addTearDown(sub.cancel);

    await h.executor.execute(run, definition, WorkflowContext());
    final stopped = (await h.repository.getById(run.id))!;
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(stopped.totalTokens, 11);
    expect(queued, hasLength(2));

    final retry = stopped.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(retry);
    await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
    final completed = (await h.repository.getById(run.id))!;
    expect(queued, hasLength(3), reason: 'retry creates only the dependent task');
    expect(completed.totalTokens, 25);
    expect(completed.tokenUsageComplete, isTrue);
  });

  test('foreach accounting recovery rechecks a settled child without replaying it', () async {
    final oldKv = h.kvService;
    final faultingKv = FaultOnceSessionKvService(filePath: oldKv.filePath);
    h.kvService = faultingKv;
    h.executor = h.makeExecutor();
    await oldKv.dispose();
    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(
          id: 'map-step',
          name: 'Map Step',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'items',
          foreachSteps: ['process'],
        ),
        WorkflowStep(id: 'process', name: 'Process', prompts: ['process']),
      ],
    );
    final run = await h.insertRun(definition);
    var dispatchCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      dispatchCount++;
      await h.completeTaskWithOutcome(e.taskId, outcome: 'succeeded', tokenCount: 9);
      if (dispatchCount == 1) faultingKv.failNextSessionRead = true;
    });
    addTearDown(sub.cancel);

    final context = h.itemsContext(['one']);
    await h.executor.execute(run, definition, context);
    final stopped = (await h.repository.getById(run.id))!;
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(dispatchCount, 1);
    expect(stopped.totalTokens, 0);
    expect(stopped.contextJson['_accounting.foreachCommittedTokens'], 0);

    final retry = stopped.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(retry);
    await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
    final completed = (await h.repository.getById(run.id))!;
    expect(dispatchCount, 1, reason: 'the settled child cannot be dispatched twice');
    expect(completed.totalTokens, 9);
    expect(completed.tokenUsageComplete, isTrue);
  });

  test('foreach accounting recovery retains in-flight sibling usage once', () async {
    final oldKv = h.kvService;
    final faultingKv = FaultOnceSessionKvService(filePath: oldKv.filePath);
    h.kvService = faultingKv;
    h.executor = h.makeExecutor();
    await oldKv.dispose();
    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(
          id: 'map-step',
          name: 'Map Step',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'items',
          foreachSteps: ['process'],
          maxParallel: 2,
        ),
        WorkflowStep(id: 'process', name: 'Process', prompts: ['process']),
      ],
    );
    final run = await h.insertRun(definition);
    var dispatchCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      dispatchCount++;
      final first = dispatchCount == 1;
      await h.completeTaskWithOutcome(e.taskId, outcome: 'succeeded', tokenCount: first ? 9 : 11);
      if (first) faultingKv.failForSessionId = (await h.taskService.get(e.taskId))!.sessionId;
    });
    addTearDown(sub.cancel);

    await h.executor.execute(run, definition, h.itemsContext(['one', 'two', 'three']));
    final stopped = (await h.repository.getById(run.id))!;
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(stopped.totalTokens, 11);
    expect(dispatchCount, 2, reason: 'the pending third item cannot start before accounting is verified');
    expect(stopped.contextJson['_accounting.baseComplete'], isTrue);

    final retry = stopped.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(retry);
    await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
    final completed = (await h.repository.getById(run.id))!;
    expect(dispatchCount, 3, reason: 'retry dispatches only the previously unstarted third item');
    final completedData = completed.contextJson['data'] as Map<String, dynamic>;
    expect(completedData['process[0].tokenCount'], isA<int>());
    expect(completedData['process[1].tokenCount'], isA<int>());
    expect(
      completedData.entries
          .where((entry) => entry.key.contains('[') && entry.key.endsWith('.tokenCount') && entry.value == null)
          .map((entry) => entry.key),
      isEmpty,
    );
    expect(completed.status, WorkflowRunStatus.completed);
    expect(completed.totalTokens, 31);
    expect(completed.tokenUsageComplete, isTrue);
  });
}
