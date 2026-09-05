@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitStrategy,
        WorkflowRun,
        WorkflowStep,
        WorkflowTaskType;
import 'package:test/test.dart';

import 'foreach_iteration_runner_test_support.dart';
import 'workflow_executor_test_support.dart';

/// Foreach-controller coverage for the two behaviours that lost their only
/// controller-driven suite when the map suite was deleted in 0.25.0:
/// index-order aggregation and the run-failure git-cleanup policy.
///
/// The third, iteration wait-timeout terminality, is not represented here: the
/// per-task wait timeout was removed from `_waitForTaskCompletion` in 0.25.0
/// and `timeout` on an agent step is now a validation error, so there is no
/// production behaviour left to pin.
typedef CleanupCall = ({String runId, String projectId, String status, bool preserveWorktrees});

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  WorkflowDefinition foreachDefinition({
    Object? maxParallel,
    WorkflowGitStrategy? gitStrategy,
    Map<String, OutputConfig> childOutputs = const {},
  }) {
    return WorkflowDefinition(
      name: 'foreach-policy',
      description: 'Foreach policy test',
      gitStrategy: gitStrategy,
      steps: [
        WorkflowStep(
          id: 'fe',
          name: 'FE',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'items',
          maxParallel: maxParallel,
          foreachSteps: const ['process'],
          outputs: const {'results': OutputConfig()},
        ),
        WorkflowStep(id: 'process', name: 'Process', prompts: const ['Process {{map.item}}'], outputs: childOutputs),
      ],
    );
  }

  group('aggregation order', () {
    test('aggregate slots follow item index even when iterations complete in reverse order', () async {
      // The aggregate feeds downstream steps positionally – slot i must be the
      // result of item i. Completion order is whatever the agents happen to
      // finish in, so an implementation that appends on completion would ship a
      // silently mis-attributed aggregate.
      final definition = foreachDefinition(maxParallel: 3, childOutputs: const {'processed': OutputConfig()});
      final run = await h.insertRun(definition);
      final context = h.itemsContext(['item0', 'item1', 'item2']);

      final dispatched = <String>[];
      final sub = h.eventBus
          .on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) => dispatched.add(e.taskId));

      final executing = h.executor.execute(run, definition, context);
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return dispatched.length < 3;
      }).timeout(const Duration(seconds: 10));
      await sub.cancel();

      // Reverse of dispatch order: each iteration reports the item its own
      // prompt was rendered with, so a mis-ordered aggregate is visible.
      for (final taskId in dispatched.reversed) {
        final task = await h.taskService.get(taskId);
        await h.seedDeclaredOutputs(taskId, {'processed': task!.description});
        await h.completeTask(taskId);
        await Future<void>.delayed(Duration.zero);
      }
      await executing;

      final results = context['results'] as List<dynamic>;
      expect(
        [for (final slot in results) ((slot as Map)['process'] as Map)['processed']],
        equals(['Process item0', 'Process item1', 'Process item2']),
        reason: 'slot i must carry item i, not the i-th iteration to finish',
      );
      expect((await h.repository.getById('run-1'))?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('run-failure git cleanup', () {
    /// Runs a one-item foreach whose iteration fails, returning the cleanup
    /// calls the host seam received.
    Future<List<CleanupCall>> runFailingForeach({
      required WorkflowDefinition definition,
      required WorkflowRun run,
      required WorkflowContext context,
    }) async {
      final calls = <CleanupCall>[];
      final executor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                calls.add((runId: runId, projectId: projectId, status: status, preserveWorktrees: preserveWorktrees));
              },
        ),
      );
      await h.repository.insert(run);
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.attachWorktree(e.taskId);
        await h.completeTask(e.taskId, status: TaskStatus.failed);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      expect((await h.repository.getById('run-1'))?.status, equals(WorkflowRunStatus.failed));
      return calls;
    }

    test('cleanup: true tears down the iteration worktrees', () async {
      // The default: a failed run must not leave per-item worktrees behind.
      final definition = foreachDefinition(gitStrategy: const WorkflowGitStrategy(cleanup: true));
      final calls = await runFailingForeach(
        definition: definition,
        run: h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'alpha'}),
        context: h.itemsContext(['a']),
      );

      expect(calls, hasLength(1));
      expect(calls.single, (runId: 'run-1', projectId: 'alpha', status: 'failed', preserveWorktrees: false));
    });

    test('cleanup: false preserves the iteration worktrees for post-mortem', () async {
      // Opting out is the whole point of the flag: the worktrees of a failed
      // run are the only place its uncommitted work survives.
      final definition = foreachDefinition(gitStrategy: const WorkflowGitStrategy(cleanup: false));
      final calls = await runFailingForeach(
        definition: definition,
        run: h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'alpha'}),
        context: h.itemsContext(['a']),
      );

      expect(calls, hasLength(1));
      expect(calls.single.preserveWorktrees, isTrue);
    });

    test('an unreadable persisted definition preserves worktrees rather than guessing', () async {
      // The policy is read back from the persisted definition. When that cannot
      // be parsed the safe answer is to keep the worktrees – deleting work on
      // an unresolvable policy is unrecoverable.
      final definition = foreachDefinition(gitStrategy: const WorkflowGitStrategy(cleanup: true));
      final calls = await runFailingForeach(
        definition: definition,
        run: h
            .makeRun(definition)
            .copyWith(variablesJson: const {'PROJECT': 'alpha'}, definitionJson: const {'steps': 'not-a-list'}),
        context: h.itemsContext(['a']),
      );

      expect(calls, hasLength(1));
      expect(calls.single.preserveWorktrees, isTrue);
    });

    test('project binding falls back to the persisted context variables', () async {
      // A run started without a PROJECT variable still has one in its context;
      // without the fallback the cleanup seam is skipped entirely and the
      // worktrees leak.
      final definition = foreachDefinition(gitStrategy: const WorkflowGitStrategy(cleanup: true));
      final context = WorkflowContext(variables: const {'PROJECT': 'context-project'})..['items'] = ['a'];
      final calls = await runFailingForeach(
        definition: definition,
        run: h.makeRun(definition).copyWith(contextJson: context.toJson()),
        context: context,
      );

      expect(calls, hasLength(1));
      expect(calls.single.projectId, equals('context-project'));
    });
  });
}
