// The typed failure vocabulary as the foreach path's decision input: what a
// settled iteration slot persists, and what a resumed run rebuilds from it.
//
// Split out of `foreach_iteration_runner_test.dart`, which is at its LOC
// ratchet.
@Tags(['component'])
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowExecutionCursor,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionSuccess,
        WorkflowGitStrategy,
        WorkflowGitWorktreeMode,
        WorkflowGitWorktreeStrategy,
        WorkflowPromotionConflictFailure,
        WorkflowRun,
        WorkflowStep,
        WorkflowTaskType;
import 'package:dartclaw_workflow/src/workflow/map_step_context.dart' show MapStepContext;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'foreach_iteration_runner_test_support.dart';
import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('continue-on-failure foreach still fails a promotion prerequisite miss', () async {
    // The four inline prerequisite guards run before callPromote, so no
    // WorkflowGitPromotionError reaches them: leaving one untyped would drop the
    // promotion-failure stop arm without any promotion-result test noticing.
    // Withholding the task worktree is what makes `implement.branch` empty.
    final definition = h.storyPipelineDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      maxParallel: 1,
      promotionAware: true,
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    final runtimeExecutor = h.makeExecutor(turnAdapter: standardTurnAdapter());

    var summarizeDispatched = false;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      if (task.title.contains('Summarize')) summarizeDispatched = true;
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<step-outcome>{"outcome":"succeeded","reason":"story done"}</step-outcome>',
      );
      await h.completeTask(e.taskId);
    });

    await runtimeExecutor.execute(
      run,
      definition,
      h.storySpecsContext(oneStorySpecs, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
    );
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, startsWith('promotion-failure:'));
    expect(summarizeDispatched, isFalse);
    final slot = (finalRun?.contextJson['data']?['story_results'] as List<dynamic>).first as Map<Object?, Object?>;
    expect(slot[MapStepContext.kindKey], equals('promotion-failure'));
    expect(slot['message'], equals('promotion failed: task worktree branch is unavailable'));
  });

  test('continue-on-failure foreach still fails an unresolved promotion conflict', () async {
    // The conflict arm of the stop set is the one the shipped suite never
    // reached: every other promotion-conflict test runs under the default
    // `onFailure: fail`, where the gate is not consulted at all.
    final definition = h.storyPipelineDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      maxParallel: 1,
      promotionAware: true,
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    final runtimeExecutor = h.makeExecutor(
      turnAdapter: standardTurnAdapter(
        promoteWorkflowBranch: ({
          required runId,
          required projectId,
          required branch,
          required integrationBranch,
          required strategy,
          String? storyId,
        }) async => const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict'),
      ),
    );

    var summarizeDispatched = false;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      if (task.title.contains('Summarize')) summarizeDispatched = true;
      await h.attachWorktree(e.taskId);
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<step-outcome>{"outcome":"succeeded","reason":"story done"}</step-outcome>',
      );
      await h.completeTask(e.taskId);
    });

    await runtimeExecutor.execute(
      run,
      definition,
      h.storySpecsContext(oneStorySpecs, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
    );
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, startsWith('promotion-conflict:'));
    expect(summarizeDispatched, isFalse, reason: 'an unresolved conflict must not advance under onFailure: continue');
    expect(finalRun?.executionCursor, isNotNull, reason: 'the conflicted item stays re-dispatchable');
    final slot = (finalRun?.contextJson['data']?['story_results'] as List<dynamic>).first as Map<Object?, Object?>;
    expect(slot[MapStepContext.kindKey], equals(WorkflowPromotionConflictFailure.kindValue));
  });

  group('typed promotion-conflict slots decide restore, not their wording', () {
    // The conflict prefix is an engine literal at every producer, so a
    // reworded conflict is only reachable by rewriting the persisted slot the
    // resume path reads. That is exactly the surface the invariant lives on:
    // `keepCursor` and the restore skip both read state that outlived a
    // restart.
    WorkflowExecutionCursor rewriteFirstSlot(
      WorkflowExecutionCursor cursor,
      Map<String, dynamic> Function(Map<String, dynamic> slot) rewrite,
    ) {
      final slots = List<dynamic>.from(cursor.resultSlots);
      slots[0] = rewrite(Map<String, dynamic>.from(slots.first as Map));
      return WorkflowExecutionCursor.foreach(
        stepId: cursor.nodeId,
        stepIndex: cursor.stepIndex,
        totalItems: cursor.totalItems ?? slots.length,
        completedIndices: cursor.completedIndices,
        failedIndices: cursor.failedIndices,
        cancelledIndices: cursor.cancelledIndices,
        resultSlots: slots,
        completedSubStepIdsByIndex: cursor.completedSubStepIdsByIndex,
      );
    }

    late WorkflowDefinition definition;
    late List<Map<String, Object>> stories;

    Future<WorkflowRun> runToConflict() async {
      definition = WorkflowDefinition(
        name: 'promotion-aware-foreach',
        description: 'Promotion-aware dependency gating',
        project: '{{PROJECT}}',
        gitStrategy: const WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          promotion: 'merge',
          publish: false,
        ),
        steps: const [
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'stories',
            foreachSteps: ['implement'],
            maxParallel: 2,
            outputs: {'story_results': OutputConfig()},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item.id}}']),
        ],
      );
      stories = [
        {'id': 'S01', 'dependencies': <String>[]},
        {
          'id': 'S02',
          'dependencies': <String>['S01'],
        },
      ];
      final run = WorkflowRun(
        id: 'run-reworded-conflict',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await h.repository.insert(run);

      final conflictExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          promoteWorkflowBranch: ({
            required runId,
            required projectId,
            required branch,
            required integrationBranch,
            required strategy,
            String? storyId,
          }) async => const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict'),
        ),
      );
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-s01',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });
      await conflictExecutor.execute(
        run,
        definition,
        WorkflowContext(data: {'stories': stories}, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
      );
      await sub.cancel();
      return (await h.repository.getById(run.id))!;
    }

    Future<WorkflowRun> resumeFrom(WorkflowExecutionCursor cursor, {required List<String> taskIds}) async {
      final conflicted = (await h.repository.getById('run-reworded-conflict'))!;
      final resuming = conflicted.copyWith(
        status: WorkflowRunStatus.running,
        errorMessage: null,
        completedAt: null,
        executionCursor: cursor,
        updatedAt: DateTime.now(),
      );
      await h.repository.update(resuming);
      final resumedExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          turnId: 'turn-2',
          promoteWorkflowBranch: ({
            required runId,
            required projectId,
            required branch,
            required integrationBranch,
            required strategy,
            String? storyId,
          }) async => const WorkflowGitPromotionSuccess(commitSha: 'abc123'),
        ),
      );
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': taskIds.length == 1 ? 'story-s01-retry' : 'story-s02',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });
      await resumedExecutor.execute(
        resuming,
        definition,
        WorkflowContext(data: {'stories': stories}, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
        startCursor: resuming.executionCursor,
      );
      await sub.cancel();
      return (await h.repository.getById('run-reworded-conflict'))!;
    }

    test('a conflict whose operator message no longer names the conflict still frees its dependent', () async {
      final conflicted = await runToConflict();
      expect(conflicted.status, equals(WorkflowRunStatus.failed));
      expect(conflicted.executionCursor, isNotNull);
      expect(conflicted.executionCursor?.cancelledIndices, isEmpty);

      final reworded = rewriteFirstSlot(
        conflicted.executionCursor!,
        (slot) => {...slot, 'message': 'the two trees did not agree'},
      );
      final rewordedSlot = reworded.resultSlots.first as Map<String, dynamic>;
      expect(
        rewordedSlot['message'],
        isNot(contains('promotion')),
        reason: 'no wording a prefix comparison could still recognise may survive in the message',
      );
      expect(rewordedSlot[MapStepContext.kindKey], equals(WorkflowPromotionConflictFailure.kindValue));

      final taskIds = <String>[];
      final resumed = await resumeFrom(reworded, taskIds: taskIds);
      expect(taskIds, hasLength(2), reason: 'S01 re-dispatches and, once promoted, releases dependent S02');
      expect(resumed.status, equals(WorkflowRunStatus.completed));
    });

    test('a failed slot with no persisted kind fails the resume and keeps the cursor', () async {
      final conflicted = await runToConflict();
      final legacy = rewriteFirstSlot(conflicted.executionCursor!, (slot) {
        slot.remove(MapStepContext.kindKey);
        return slot;
      });

      final taskIds = <String>[];
      final resumed = await resumeFrom(legacy, taskIds: taskIds);
      expect(taskIds, isEmpty, reason: 'the run must not dispatch off state it cannot classify');
      expect(resumed.status, equals(WorkflowRunStatus.failed));
      expect(resumed.errorMessage, contains('workflow failure vocabulary'));
      expect(resumed.errorMessage, contains('Start a fresh run.'));
      expect(resumed.executionCursor, isNotNull, reason: 'the legacy cursor still shows where the run stopped');
    });

    test('a failed slot with an unrecognised kind fails the resume the same way', () async {
      final conflicted = await runToConflict();
      final unknown = rewriteFirstSlot(
        conflicted.executionCursor!,
        (slot) => {...slot, MapStepContext.kindKey: 'kind-from-a-later-release'},
      );

      final taskIds = <String>[];
      final resumed = await resumeFrom(unknown, taskIds: taskIds);
      expect(taskIds, isEmpty);
      expect(resumed.status, equals(WorkflowRunStatus.failed));
      expect(resumed.errorMessage, contains('workflow failure vocabulary'));
      expect(resumed.executionCursor, isNotNull);
    });

    test('a legacy cancelled slot still restores, because it loses no recovery path', () async {
      // The dependent S02 is the cancelled one, so the prerequisite S01 is
      // still free to dispatch and the restore is observable as work, not as
      // the absence of a failure.
      final conflicted = await runToConflict();
      final legacyCancelled = WorkflowExecutionCursor.foreach(
        stepId: conflicted.executionCursor!.nodeId,
        stepIndex: conflicted.executionCursor!.stepIndex,
        totalItems: 2,
        completedIndices: const [1],
        cancelledIndices: const [1],
        resultSlots: [
          null,
          {'error': true, 'message': 'Cancelled: dispatch stall'},
        ],
      );

      final taskIds = <String>[];
      final resumed = await resumeFrom(legacyCancelled, taskIds: taskIds);
      expect(resumed.errorMessage, isNot(contains('workflow failure vocabulary')));
      expect(taskIds, hasLength(1), reason: 'a cancelled slot restores as settled without a discriminator');
      expect(resumed.status, equals(WorkflowRunStatus.completed));
    });
  });
}
