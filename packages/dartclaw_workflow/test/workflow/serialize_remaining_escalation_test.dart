// S61 component tests: serialize-remaining escalation — settle, serial retry, event.
//
// Tests cover the seven scenarios from the FIS plus BPC-11/12/13/23/32
// and the TI01 event class shape.
//
// Tier note: tests that drive the full executor with SQLite are tagged
// `component`. Pure unit tests (event class shape, flag persistence round-trip)
// run at the default tier.
@Tags(['component'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowGitWorktreeMode, WorkflowTaskType;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        MergeResolveConfig,
        MergeResolveEscalation,
        OutputConfig,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowExecutor,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionSuccess,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowSerializationEnactedEvent,
        WorkflowStep,
        WorkflowStepOutputTransformer,
        WorkflowTurnAdapter;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart' show WorkflowExecutorHarness, standardTurnAdapter;

void main() {
  // Unit tests for event class shape are in serialization_enacted_event_test.dart.

  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  WorkflowExecutor makeExecutor({
    WorkflowTurnAdapter? turnAdapter,
    WorkflowStepOutputTransformer? outputTransformer,
    required Directory dir,
    Duration serializeRemainingSettleTimeout = const Duration(seconds: 30),
  }) {
    return h.makeExecutor(
      turnAdapter: turnAdapter,
      outputTransformer: outputTransformer,
      dataDir: dir.path,
      serializeRemainingSettleTimeout: serializeRemainingSettleTimeout,
    );
  }

  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) =>
      h.completeTask(taskId, status: status);

  /// Builds a definition with a foreach step that has merge-resolve enabled.
  ///
  /// Uses a ForeachNode (controller + child step) so the path goes through
  /// _executeForeachStep (which has the S61 implementation), not _executeMapStep.
  WorkflowDefinition makeMergeResolveDefinition({
    required String escalation,
    int maxAttempts = 1,
    int maxParallel = 2,
    bool secondChild = false,
  }) {
    return WorkflowDefinition(
      name: 'mr-wf',
      description: 'Merge-resolve test workflow',
      project: '{{PROJECT}}',
      gitStrategy: WorkflowGitStrategy(
        integrationBranch: true,
        worktree: const WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
        promotion: 'merge',
        publish: false,
        mergeResolve: MergeResolveConfig(
          enabled: true,
          maxAttempts: maxAttempts,
          escalation: escalation == 'serialize-remaining'
              ? MergeResolveEscalation.serializeRemaining
              : MergeResolveEscalation.fail,
        ),
      ),
      steps: [
        WorkflowStep(
          id: 'pipeline',
          name: 'Story Pipeline',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'stories',
          maxParallel: maxParallel,
          foreachSteps: secondChild ? const ['implement', 'verify'] : const ['implement'],
          outputs: const {'results': OutputConfig()},
        ),
        WorkflowStep(id: 'implement', name: 'Implement Story', prompts: const ['Implement {{map.item.id}}']),
        if (secondChild) WorkflowStep(id: 'verify', name: 'Verify Story', prompts: const ['Verify {{map.item.id}}']),
      ],
    );
  }

  WorkflowRun makeRun(WorkflowDefinition definition, {String id = 'run-1'}) {
    final now = DateTime.now();
    return WorkflowRun(
      id: id,
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
      variablesJson: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
    );
  }

  // Builds a WorkflowTurnAdapter where promoteWorkflowBranch: conflict for
  // storyIds in [conflictIds], success otherwise. Also provides a fake
  // cleanupWorktreeForRetry that always succeeds.
  WorkflowTurnAdapter makeAdapter({required Set<String> conflictIds, Map<String, String>? successShas}) {
    return standardTurnAdapter(
      promoteWorkflowBranch:
          ({
            required runId,
            required projectId,
            required branch,
            required integrationBranch,
            required strategy,
            String? storyId,
          }) async {
            if (storyId != null && conflictIds.contains(storyId)) {
              return const WorkflowGitPromotionConflict(
                conflictingFiles: ['lib/story.dart'],
                details: 'merge conflict',
              );
            }
            return WorkflowGitPromotionSuccess(commitSha: successShas?[storyId] ?? 'sha-${storyId ?? 'unknown'}');
          },
      cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
      captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre-attempt',
    );
  }

  // outputTransformer that:
  // - Injects `${step.id}.branch = 'story-branch-${task.id}'` for coding steps
  //   so the promotion path finds a branch name in iterContext.
  // - Returns `merge_resolve.outcome = 'failed'` for merge-resolve skill steps.
  Map<String, dynamic> Function(dynamic, dynamic, WorkflowStep, dynamic, Map<String, dynamic>)
  codingWithMergeResolveFailTransformer() {
    return (run, definition, step, task, outputs) {
      if (step.id.startsWith('_merge_resolve_')) {
        return {
          'merge_resolve.outcome': 'failed',
          'merge_resolve.error_message': 'simulated failure',
          'merge_resolve.conflicted_files': <String>['lib/story.dart'],
          'merge_resolve.resolution_summary': '',
        };
      }
      // Inject branch for coding steps so promotion has a branch to merge.
      final result = Map<String, dynamic>.from(outputs);
      if (step.taskType == WorkflowTaskType.agent) {
        result['${step.id}.branch'] = 'story-branch-${task.id}';
      }
      return result;
    };
  }

  // outputTransformer that injects branch for coding steps (no merge-resolve override).
  Map<String, dynamic> Function(dynamic, dynamic, WorkflowStep, dynamic, Map<String, dynamic>)
  codingWithBranchTransformer() {
    return (run, definition, step, task, outputs) {
      final result = Map<String, dynamic>.from(outputs);
      if (step.taskType == WorkflowTaskType.agent) {
        result['${step.id}.branch'] = 'story-branch-${task.id}';
      }
      return result;
    };
  }

  group('S1 — happy: last-unfinished-iteration (two-story motivating case)', () {
    test('serialize-remaining fires once, story 2 re-queued at head, workflow completes', () async {
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 2);
      final run = makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      // S01 succeeds on promote. S02 conflicts, merge-resolve fails, then
      // serialize-remaining requeues S02 at the head for a serial retry.
      final s02PromoteCount = <int>[0];
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S02') {
                s02PromoteCount[0]++;
                // Initial promotion conflicts; the serial re-run succeeds.
                if (s02PromoteCount[0] == 1) {
                  return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
                }
              }
              return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
      );

      final taskCount = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount.add(e.taskId);
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      // Exactly one serialization event (BPC-11).
      expect(serializationEvents, hasLength(1));
      final evt = serializationEvents.first;
      expect(evt.runId, run.id);
      expect(evt.foreachStepId, 'pipeline');
      expect(evt.failingIterationIndex, 1); // S02 is index 1
      expect(evt.failedAttemptNumber, 1);

      // Workflow must complete (S02 re-run succeeded serially).
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('two distinct iterations exhausting merge-resolve are both re-queued; neither is dropped', () async {
      // Regression: when a second distinct in-flight iteration exhausts
      // merge-resolve while the first is already `enacting`, it returned the
      // idempotent serialize sentinel and removed itself from `inFlight` before
      // the serial queue saw it — so it was neither the typed state's iterIndex
      // nor in `pending`, and was dropped from the rebuilt serial queue (null
      // result slot). Every serialize-exhausted iteration must stay queue-visible.
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 3);
      final run = makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      // S01 always succeeds. S02 and S03 both conflict on their first (parallel)
      // promote, then succeed on the serial re-run after siblings settle.
      final promoteCounts = <String, int>{};
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S02' || storyId == 'S03') {
                final attempt = (promoteCounts[storyId!] ?? 0) + 1;
                promoteCounts[storyId] = attempt;
                if (attempt == 1) {
                  return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
                }
              }
              return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(
        finalRun?.status,
        equals(WorkflowRunStatus.completed),
        reason: 'both exhausted iterations must be re-queued and complete',
      );
      final results = finalRun?.contextJson['data']?['results'] as List<Object?>?;
      expect(results, isNotNull);
      expect(results, hasLength(3), reason: 'all three stories must retain a result slot');
      expect(
        results!.every((value) => value != null),
        isTrue,
        reason: 'no exhausted iteration may be dropped with a null result slot: $results',
      );
    });
  });

  group('S3 — idempotent re-firing', () {
    test('second call to _handleMergeResolveEscalation with flag=true emits no second event', () async {
      // We simulate idempotency by running a workflow where serialize-remaining
      // fires and then a serial-mode iteration also exhausts merge-resolve.
      // In serial mode the second escalation call finds the flag already set
      // and must NOT emit a second event.
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 2);
      final run = makeRun(definition, id: 'run-idempotent');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      // Both stories always conflict → serialize-remaining on S02 → S02 re-queued →
      // serial retry also conflicts → second escalation call finds flag=true → no second event.
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S01') {
                return const WorkflowGitPromotionSuccess(commitSha: 'sha-s01');
              }
              // S02 always conflicts.
              return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      // Only ONE serialization event even though S02 exhausted attempts twice (BPC-11).
      expect(serializationEvents, hasLength(1));
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      final results = finalRun?.contextJson['data']?['results'] as List<Object?>?;
      expect(results, isNotNull);
      expect(
        results![1],
        isA<Map<Object?, Object?>>().having((value) => value['message'], 'message', contains('conflict')),
      );
    });
  });

  group('S7 — non-merge failure does not trigger serialize-remaining', () {
    test('generic step failure in serial mode does not emit WorkflowSerializationEnactedEvent', () async {
      // A plain step failure (not a promotion conflict) must not trigger
      // serialize-remaining at any point.
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 1);
      final run = makeRun(definition, id: 'run-non-merge-fail');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      // No promotion callback — step itself just fails normally.
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => const WorkflowGitPromotionSuccess(commitSha: 'sha-ok'),
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(dir: h.tempDir, turnAdapter: adapter);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        // Generic task failure — not a merge conflict.
        await completeTask(e.taskId, status: TaskStatus.failed);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      expect(serializationEvents, isEmpty);
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });
  });

  group('enabled:false — no serialization event emitted', () {
    test('merge_resolve.enabled=false yields normal promotion-conflict failure (no event)', () async {
      final definition = WorkflowDefinition(
        name: 'mr-disabled',
        description: 'merge-resolve disabled',
        project: '{{PROJECT}}',
        gitStrategy: const WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          promotion: 'squash',
          publish: false,
          mergeResolve: MergeResolveConfig(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 2,
            outputs: {'results': OutputConfig()},
          ),
        ],
      );
      final run = makeRun(definition, id: 'run-mr-disabled');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      final adapter = makeAdapter(conflictIds: {'S01'});
      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithBranchTransformer(),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      // No event when merge_resolve is disabled.
      expect(serializationEvents, isEmpty);
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });
  });

  group('S2 — edge: mid-flight siblings settle', () {
    test('serialize event fires while sibling settles without cancellation', () async {
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 3);
      final run = makeRun(definition, id: 'run-s2');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      final queuedTaskIds = <String>[];
      final releaseS03 = Completer<void>();
      final releaseOnEvent = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen((_) {
        if (!releaseS03.isCompleted) releaseS03.complete();
      });

      // S02 conflicts on first promote; succeeds on serial retry.
      final s02PromoteCount = <int>[0];
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S02') {
                s02PromoteCount[0]++;
                if (s02PromoteCount[0] == 1) {
                  return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
                }
              }
              return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        if (!queuedTaskIds.contains(e.taskId)) {
          queuedTaskIds.add(e.taskId);
        }
        final taskOrdinal = queuedTaskIds.indexOf(e.taskId) + 1;
        if (taskOrdinal == 3) {
          await releaseS03.future;
        }
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();
      await releaseOnEvent.cancel();

      expect(serializationEvents, hasLength(1));
      final evt = serializationEvents.first;
      expect(evt.failingIterationIndex, 1); // S02 is index 1
      expect((await h.taskService.get(queuedTaskIds[2]))?.status, equals(TaskStatus.accepted));

      // Workflow completes (serial re-runs all succeed).
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('settle vs interruption', () {
    test('a genuinely cancelled in-flight sibling pauses instead of being un-aborted', () async {
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 3);
      final run = makeRun(definition, id: 'run-settle-interruption');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      // S02 conflicts on its first (parallel) promote and succeeds on the
      // serial retry; S01 and S03 always promote cleanly.
      final s02PromoteCount = <int>[0];
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S02') {
                s02PromoteCount[0]++;
                if (s02PromoteCount[0] == 1) {
                  return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
                }
              }
              return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
      );

      final s03TaskIds = <String>[];
      final releaseS03 = Completer<void>();
      final cancelS03OnEvent = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen((_) async {
        while (s03TaskIds.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        await h.taskService.transition(s03TaskIds.first, TaskStatus.cancelled, trigger: 'operator-cancel');
        if (!releaseS03.isCompleted) releaseS03.complete();
      });
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await h.taskService.get(e.taskId);
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        if (task?.configJson['displayScope'] == 'S03') {
          s03TaskIds.add(e.taskId);
          if (s03TaskIds.length == 1) {
            await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
            await releaseS03.future;
            return;
          }
        }
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await cancelS03OnEvent.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(
        finalRun?.status,
        equals(WorkflowRunStatus.paused),
        reason: 'a genuine sibling cancellation during settle must not be masked by the old abort reset',
      );
      expect(s03TaskIds, hasLength(1), reason: 'the cancelled sibling is not re-dispatched as a settle casualty');
      expect((await h.taskService.get(s03TaskIds.first))?.status, equals(TaskStatus.cancelled));
    });
  });

  group('first-task attribution', () {
    test('an unexpected later-child failure is attributed to the write-once first task id', () async {
      final definition = makeMergeResolveDefinition(
        escalation: 'fail',
        maxAttempts: 1,
        maxParallel: 1,
        secondChild: true,
      );
      final run = makeRun(definition, id: 'run-first-task-attribution');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: makeAdapter(conflictIds: {}),
        outputTransformer: (run, definition, step, task, outputs) {
          if (step.id == 'verify') throw StateError('simulated later-child crash');
          return codingWithBranchTransformer()(run, definition, step, task, outputs);
        },
      );

      final queuedTaskIds = <String>[];
      final iterationEvents = <MapIterationCompletedEvent>[];
      final iterSub = h.eventBus.on<MapIterationCompletedEvent>().listen(iterationEvents.add);
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        queuedTaskIds.add(e.taskId);
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await iterSub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(queuedTaskIds, hasLength(2));
      expect(iterationEvents.single.taskId, equals(queuedTaskIds.first));
    });
  });

  group('S4/S5 — error: stuck sibling during settle', () {
    test('settle-timeout fails the run and cancels active tasks by workflow run id', () async {
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 3);
      final run = makeRun(definition, id: 'run-settle-timeout');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final s03TaskIds = <String>[];
      final cancelledByRun = <String>[];
      final cancelSub = h.eventBus
          .on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.cancelled && e.trigger == 'serialize-remaining-settle-timeout')
          .listen((e) => cancelledByRun.add(e.taskId));

      final s02PromoteCount = <int>[0];
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S02') {
                s02PromoteCount[0]++;
                if (s02PromoteCount[0] == 1) {
                  return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
                }
              }
              return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
        serializeRemainingSettleTimeout: Duration.zero,
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await h.taskService.get(e.taskId);
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        if (task?.configJson['displayScope'] == 'S03') {
          s03TaskIds.add(e.taskId);
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          return;
        }
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await cancelSub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('serialize-remaining settle-timeout'));
      expect(s03TaskIds, hasLength(1));
      expect(cancelledByRun, contains(s03TaskIds.single));
      expect((await h.taskService.get(s03TaskIds.single))?.status, equals(TaskStatus.cancelled));
    });

    test('settle-timeout keeps one deadline after another sibling settles', () async {
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 4);
      final run = makeRun(definition, id: 'run-settle-timeout-deadline');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
            {'id': 'S04'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationStarted = Completer<void>();
      final settleStopwatch = Stopwatch();
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen((_) {
        if (!serializationStarted.isCompleted) {
          settleStopwatch.start();
          serializationStarted.complete();
        }
      });
      final s03TaskIds = <String>[];
      final s04TaskIds = <String>[];

      final s02PromoteCount = <int>[0];
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S02') {
                s02PromoteCount[0]++;
                if (s02PromoteCount[0] == 1) {
                  return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/story.dart'], details: 'conflict');
                }
              }
              return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
        serializeRemainingSettleTimeout: const Duration(milliseconds: 300),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await h.taskService.get(e.taskId);
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        if (task?.configJson['displayScope'] == 'S03') {
          s03TaskIds.add(e.taskId);
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          unawaited(
            Future<void>(() async {
              await serializationStarted.future;
              await Future<void>.delayed(const Duration(milliseconds: 200));
              await completeTask(e.taskId);
            }),
          );
          return;
        }
        if (task?.configJson['displayScope'] == 'S04') {
          s04TaskIds.add(e.taskId);
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          return;
        }
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('serialize-remaining settle-timeout'));
      expect(s03TaskIds, hasLength(1));
      expect(s04TaskIds, hasLength(1));
      expect(settleStopwatch.elapsedMilliseconds, lessThan(450));
      expect((await h.taskService.get(s03TaskIds.single))?.status, equals(TaskStatus.accepted));
      expect((await h.taskService.get(s04TaskIds.single))?.status, equals(TaskStatus.cancelled));
    });
  });

  group('S5 — crash recovery during serialize settle', () {
    test('pending serialize state enters serial mode before dispatching earlier pending work', () async {
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 2);
      final run = makeRun(definition, id: 'run-pending-before-dispatch');
      await h.repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
          ],
          '_merge_resolve.serializeRemaining': {
            'stepId': 'pipeline',
            'phase': 'enacting',
            'iterIndex': 1,
            'failedAttemptNumber': 1,
            'eventEmitted': true,
          },
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}'),
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );
      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithBranchTransformer(),
      );

      final queuedScopes = <Object?>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await h.taskService.get(e.taskId);
        queuedScopes.add(task?.configJson['displayScope']);
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(queuedScopes, isNotEmpty);
      expect(queuedScopes.first, equals('S02'));
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('pending serialize state is enacted before budget cancellation', () async {
      final definition = makeMergeResolveDefinition(
        escalation: 'serialize-remaining',
        maxAttempts: 1,
        maxParallel: 1,
      ).copyWith(maxTokens: 1);
      final run = makeRun(definition, id: 'run-serialize-before-budget');
      await h.repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: makeAdapter(conflictIds: {'S01'}),
        outputTransformer: codingWithMergeResolveFailTransformer(),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await h.completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"completed"}</step-outcome>',
          tokenCount: 10,
        );
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('budget exhausted'));
      expect(serializationEvents, hasLength(1));
      expect(
        finalRun?.contextJson['data']?['_merge_resolve.serializeRemaining'],
        isA<Map<Object?, Object?>>()
            .having((state) => state['phase'], 'phase', 'drained')
            .having((state) => state['eventEmitted'], 'eventEmitted', isTrue),
      );
    });

    test('resume with serialize state enacting resumes in serial mode, no second event', () async {
      // Simulate server crash mid-settle: pre-seed typed serialize state in `enacting`.
      // On resume, the foreach controller enters serial mode and must not fire a
      // second WorkflowSerializationEnactedEvent when eventEmitted is already true.
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 2);
      final run = makeRun(definition, id: 'run-s5');
      await h.repository.insert(run);

      // Pre-seed context as if crash happened after enacting but before sibling settle completed.
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
          ],
          '_merge_resolve.serializeRemaining': {
            'stepId': 'pipeline',
            'phase': 'enacting',
            'iterIndex': 1,
            'failedAttemptNumber': 1,
            'eventEmitted': true,
          },
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      // S02 succeeds on its serial retry (crash recovery resumes at head).
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}'),
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithBranchTransformer(),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      expect(serializationEvents, isEmpty);

      // Workflow must complete (serial re-run succeeds).
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('S6 — edge: already-promoted iterations untouched', () {
    test('stories 1+2 already promoted, story 3 exhausts attempts, only 3+4 re-queued', () async {
      // 4 stories; story 3 exhausts merge-resolve.
      // After serial-mode enactment: stories 1+2 must NOT appear in the serial queue (already promoted).
      // Stories 3 (failing, at head) and 4 (sibling) enter serial queue.
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 4);
      final run = makeRun(definition, id: 'run-s6');
      await h.repository.insert(run);

      // Pre-seed stories 1+2 as already promoted so the executor skips them.
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
            {'id': 'S02'},
            {'id': 'S03'},
            {'id': 'S04'},
          ],
          '_map.pipeline.promotedIds': ['S01', 'S02'],
          'pipeline[0].promotion': 'success',
          'pipeline[0].promotion_sha': 'sha-s01',
          'pipeline[1].promotion': 'success',
          'pipeline[1].promotion_sha': 'sha-s02',
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final serializationEvents = <WorkflowSerializationEnactedEvent>[];
      final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

      // S03 conflicts on first attempt (serialize-remaining); succeeds on serial retry.
      final s03PromoteCount = <int>[0];
      final adapter = standardTurnAdapter(
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              if (storyId == 'S03') {
                s03PromoteCount[0]++;
                if (s03PromoteCount[0] == 1) {
                  return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/s3.dart'], details: 'conflict');
                }
              }
              return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'x'}');
            },
        cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async => null,
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre',
      );

      final executor = makeExecutor(
        dir: h.tempDir,
        turnAdapter: adapter,
        outputTransformer: codingWithMergeResolveFailTransformer(),
      );

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch-${e.taskId}',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await eventSub.cancel();

      // Exactly one event; failing iter is S03 (index 2).
      expect(serializationEvents, hasLength(1));
      final evt = serializationEvents.first;
      expect(evt.failingIterationIndex, 2); // S03 is index 2
      // Workflow must complete.
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('MapStepCompletedEvent / MapIterationCompletedEvent — no regression', () {
    test('existing events still fire after S61 changes', () async {
      final definition = makeMergeResolveDefinition(escalation: 'serialize-remaining', maxAttempts: 1, maxParallel: 1);
      final run = makeRun(definition, id: 'run-events');
      await h.repository.insert(run);
      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
      );

      final mapCompletedEvents = <MapStepCompletedEvent>[];
      final iterCompletedEvents = <MapIterationCompletedEvent>[];
      final mapSub = h.eventBus.on<MapStepCompletedEvent>().listen(mapCompletedEvents.add);
      final iterSub = h.eventBus.on<MapIterationCompletedEvent>().listen(iterCompletedEvents.add);

      final adapter = makeAdapter(conflictIds: {});
      final executor = makeExecutor(dir: h.tempDir, turnAdapter: adapter);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await h.taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
            'branch': 'story-branch',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await mapSub.cancel();
      await iterSub.cancel();

      expect(mapCompletedEvents, hasLength(1));
      expect(iterCompletedEvents, hasLength(1));
    });
  });
}
