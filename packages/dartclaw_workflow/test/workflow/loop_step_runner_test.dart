// Focused component tests for loop step runner behavior.
// The existing loop_execution_test.dart covers the full feature matrix;
// these tests are additive for fast regression localization.
@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnErrorPolicy,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowExecutionCursorNodeType,
        WorkflowLoop,
        WorkflowRunStatus,
        WorkflowStep;
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

  test('onMaxIterations: continue advances to the next step on exhaustion (TI04)', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
        const WorkflowStep(id: 'after', name: 'After', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(
          id: 'l1',
          steps: ['ls'],
          maxIterations: 2,
          exitGate: 'never == true',
          onMaxIterations: WorkflowLoop.onMaxIterationsContinue,
        ),
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

    // 2 loop iterations (gate never passes) + 1 sequential 'after' = 3 tasks;
    // the run completes instead of failing at the loop.
    expect(taskCount, equals(3));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('default fail policy still fails before the following step on exhaustion (TI04)', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
        const WorkflowStep(id: 'after', name: 'After', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['ls'], maxIterations: 2, exitGate: 'never == true'),
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

    // 2 loop iterations only; the run fails at the loop, the 'after' step never runs.
    expect(taskCount, equals(2));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
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

  test('cancelled top-level loop body task pauses at the loop cursor without git cleanup', () async {
    final cleanupCalls = <String>[];
    final executor = h.makeExecutor(
      turnAdapter: standardTurnAdapter(
        cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
          cleanupCalls.add(status);
        },
      ),
    );
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['ls'], maxIterations: 3, exitGate: 'ls.status == accepted'),
      ],
    );
    // PROJECT arms the cleanup callback path: without it the cleanup seam
    // no-ops and the "not invoked" assertion would pass vacuously.
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'proj'});
    await h.repository.insert(run);

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId, status: TaskStatus.cancelled);
    });

    await executor.execute(run, definition, WorkflowContext(variables: const {'PROJECT': 'proj'}));
    await sub.cancel();

    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    // The pause reason distinguishes a teardown interruption from an approval hold.
    expect(
      finalRun?.errorMessage,
      "Step 'ls' was interrupted by task cancellation; resume re-runs it from its checkpoint.",
    );
    final cursor = finalRun?.executionCursor;
    expect(cursor?.nodeType, equals(WorkflowExecutionCursorNodeType.loop));
    expect(cursor?.nodeId, equals('l1'));
    expect(cursor?.stepId, equals('ls'));
    expect(cursor?.iteration, equals(1));
    expect(cleanupCalls, isEmpty, reason: 'teardown pause must not destroy worktrees via cleanupWorkflowGit');
  });

  test('resume after a cancelled top-level loop pause re-dispatches the step at the same iteration', () async {
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

    var cancelNext = true;
    final taskTitles = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      taskTitles.add(task?.title ?? '');
      if (cancelNext) {
        cancelNext = false;
        await h.completeTask(e.taskId, status: TaskStatus.cancelled);
      } else {
        await h.completeTask(e.taskId);
      }
    });

    await h.executor.execute(run, definition, WorkflowContext());

    final pausedRun = await h.repository.getById('run-1');
    expect(pausedRun?.status, equals(WorkflowRunStatus.paused));
    expect(taskTitles, hasLength(1));

    // Resume from the exact persisted state the cancelled pause produced.
    final resumedRun = pausedRun!.copyWith(
      status: WorkflowRunStatus.running,
      errorMessage: null,
      updatedAt: DateTime.now(),
    );
    await h.repository.update(resumedRun);
    final resumedContext = WorkflowContext.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(resumedRun.contextJson)) as Map),
    );
    await h.executor.execute(resumedRun, definition, resumedContext, startCursor: resumedRun.executionCursor);
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(taskTitles, hasLength(2), reason: 'resume re-dispatches the cancelled step');
    // Both dispatches target the same loop iteration – the checkpoint was not advanced.
    expect(taskTitles[0], contains('l1 iter 1'));
    expect(taskTitles[1], contains('l1 iter 1'));
  });

  test('cancelled body step with onError: continue still pauses instead of continuing the loop', () async {
    // Interruption precedes onError: continue – continuing would dispatch the
    // next body task mid-teardown, defeating the point of the teardown.
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 's1', name: 'S1', prompts: ['p'], onError: OnErrorPolicy.continueWorkflow),
        const WorkflowStep(id: 's2', name: 'S2', prompts: ['p']),
      ],
      loops: [
        const WorkflowLoop(id: 'l1', steps: ['s1', 's2'], maxIterations: 2, exitGate: 's2.status == accepted'),
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
      await h.completeTask(e.taskId, status: TaskStatus.cancelled);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    expect(taskCount, equals(1), reason: 'the next body step must not be dispatched after a teardown-cancelled task');
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.paused));
    expect(finalRun?.errorMessage, contains("'s1'"));
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
