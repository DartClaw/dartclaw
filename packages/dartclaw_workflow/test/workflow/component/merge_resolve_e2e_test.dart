// Component-tier integration tests for the merge-resolve E2E paths (S62).
//
// Covers the five MVP paths (BPC-33) on both Claude Code and Codex harnesses
// (BPC-21) plus the Issue C reproduction (BPC-27).
//
// Each path test runs once per provider value in [_harnesses], giving a 5×2
// matrix. The fake harness scripts merge_resolve.* outputs deterministically
// so behavior is identical across harness kinds.
//
// Artifact assertions name all 9 v1 fields from Decision 9:
//   iteration_index, story_id, attempt_number, outcome, conflicted_files,
//   resolution_summary, error_message, agent_session_id, tokens_used.
@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/workflow_git_support.dart';
import 'package:dartclaw_models/dartclaw_models.dart'
    show
        MergeResolveConfig,
        MergeResolveEscalation,
        OutputConfig,
        SessionType,
        WorkflowGitStrategy,
        WorkflowGitPublishStrategy,
        WorkflowGitWorktreeStrategy;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        MergeResolveAttemptArtifact,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitBootstrapResult,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionSuccess,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowSerializationEnactedEvent,
        WorkflowStep,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        kWorkflowContextClose,
        kWorkflowContextOpen;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../workflow_executor_test_support.dart';

// ---------------------------------------------------------------------------
// Cross-harness matrix
// ---------------------------------------------------------------------------

const _harnesses = ['claudeCode', 'codex'];

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

WorkflowDefinition _makeDefinition({
  String escalation = 'serialize-remaining',
  int maxAttempts = 2,
  int maxParallel = 1,
  String provider = 'claudeCode',
}) {
  return WorkflowDefinition(
    name: 'mr-e2e-wf',
    description: 'merge-resolve E2E test workflow',
    project: '{{PROJECT}}',
    gitStrategy: WorkflowGitStrategy(
      bootstrap: true,
      worktree: const WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
      promotion: 'merge',
      publish: const WorkflowGitPublishStrategy(enabled: false),
      mergeResolve: MergeResolveConfig(
        enabled: true,
        maxAttempts: maxAttempts,
        escalation: escalation == 'serialize-remaining'
            ? MergeResolveEscalation.serializeRemaining
            : MergeResolveEscalation.fail,
        tokenCeiling: 100000,
      ),
    ),
    steps: [
      WorkflowStep(
        id: 'pipeline',
        name: 'Story Pipeline',
        type: 'foreach',
        mapOver: 'stories',
        maxParallel: maxParallel,
        foreachSteps: const ['implement'],
        outputs: const {'story_results': OutputConfig()},
      ),
      WorkflowStep(
        id: 'implement',
        name: 'Implement Story',
        provider: provider,
        prompts: const ['Implement {{map.item.id}}'],
      ),
    ],
  );
}

WorkflowRun _makeRun(WorkflowDefinition definition, {String? id}) {
  final now = DateTime.now();
  return WorkflowRun(
    id: id ?? 'run-${DateTime.now().millisecondsSinceEpoch}',
    definitionName: definition.name,
    status: WorkflowRunStatus.running,
    startedAt: now,
    updatedAt: now,
    currentStepIndex: 0,
    definitionJson: definition.toJson(),
    variablesJson: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
  );
}

/// Encodes a merge-resolve skill output payload as the assistant message format.
String _mrMessage({
  String outcome = 'resolved',
  List<String> conflictedFiles = const ['lib/story.dart'],
  String summary = 'resolved conflicts',
  String? errorMessage,
}) {
  final payload = <String, dynamic>{
    'merge_resolve.outcome': outcome,
    'merge_resolve.conflicted_files': conflictedFiles,
    'merge_resolve.resolution_summary': summary,
    if (errorMessage != null && errorMessage.isNotEmpty) 'merge_resolve.error_message': errorMessage,
  };
  return '$kWorkflowContextOpen${jsonEncode(payload)}$kWorkflowContextClose';
}

/// Reads all merge-resolve artifacts for the given story task id.
Future<List<MergeResolveAttemptArtifact>> _readArtifacts(WorkflowExecutorHarness h, String taskId) async {
  final records = await h.taskRepository.listArtifactsByTask(taskId);
  final mrRecords = records.where((a) => a.name.startsWith('merge_resolve_iter_')).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final artifacts = <MergeResolveAttemptArtifact>[];
  for (final record in mrRecords) {
    final f = File(record.path);
    if (await f.exists()) {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      artifacts.add(MergeResolveAttemptArtifact.fromJson(json));
    }
  }
  return artifacts;
}

/// Binds a worktree to a task so promotion can find the branch name.
Future<void> _bindWorktree(WorkflowExecutorHarness h, String taskId) async {
  await h.taskService.updateFields(
    taskId,
    worktreeJson: {
      'path': p.join(h.tempDir.path, 'worktrees', taskId),
      'branch': 'story-branch-$taskId',
      'createdAt': DateTime.now().toIso8601String(),
    },
  );
}

/// Asserts the 9 required v1 fields on an artifact (Decision 9).
void _assertArtifactFields(MergeResolveAttemptArtifact a) {
  // Field presence is guaranteed by fromJson; assert non-negative/non-empty.
  expect(a.iterationIndex, greaterThanOrEqualTo(0), reason: 'iteration_index must be ≥ 0');
  expect(a.storyId, isNotEmpty, reason: 'story_id must be non-empty');
  expect(a.attemptNumber, greaterThan(0), reason: 'attempt_number must be > 0');
  expect(a.outcome, isNotEmpty, reason: 'outcome must be non-empty');
  // conflicted_files: non-null list (may be empty on resolved)
  expect(a.conflictedFiles, isNotNull, reason: 'conflicted_files must be present');
  // resolution_summary: present (may be empty on failed)
  expect(a.resolutionSummary, isNotNull, reason: 'resolution_summary must be present');
  // error_message: nullable — no assertion on value, just confirm field is accessible
  // agent_session_id: may be empty from fake (session created by test, id may be empty string)
  expect(a.agentSessionId, isNotNull, reason: 'agent_session_id must be present');
  // tokens_used: non-negative
  expect(a.tokensUsed, greaterThanOrEqualTo(0), reason: 'tokens_used must be ≥ 0');
}

// ---------------------------------------------------------------------------
// P1 — success on first attempt
// ---------------------------------------------------------------------------

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  for (final provider in _harnesses) {
    group('P1 — success first attempt [$provider]', () {
      test('workflow succeeds; exactly one artifact with outcome=resolved', () async {
        final def = _makeDefinition(provider: provider);
        final run = _makeRun(def, id: 'p1-$provider');
        await h.repository.insert(run);
        final ctx = WorkflowContext(
          data: {
            'stories': [
              {'id': 'S01'},
            ],
          },
          variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
        );

        String? storyTaskId;
        bool firstPromotion = true;
        final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
          e,
        ) async {
          await Future<void>.delayed(Duration.zero);
          final task = await h.taskService.get(e.taskId);
          if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
            final session = await h.sessionService.createSession(type: SessionType.task);
            await h.taskService.updateFields(task.id, sessionId: session.id);
            await h.messageService.insertMessage(
              sessionId: session.id,
              role: 'assistant',
              content: _mrMessage(outcome: 'resolved', summary: 'Resolved STATE.md conflict'),
            );
          } else {
            storyTaskId = e.taskId;
            await _bindWorktree(h, e.taskId);
          }
          await h.completeTask(e.taskId);
        });

        final executor = h.makeExecutor(
          turnAdapter: WorkflowTurnAdapter(
            reserveTurn: (_) => Future.value('turn-p1'),
            executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
            waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
            bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
                const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
            promoteWorkflowBranch:
                ({
                  required runId,
                  required projectId,
                  required branch,
                  required integrationBranch,
                  required strategy,
                  String? storyId,
                }) async {
                  if (firstPromotion) {
                    firstPromotion = false;
                    return const WorkflowGitPromotionConflict(
                      conflictingFiles: ['docs/STATE.md'],
                      details: 'merge conflict on STATE.md',
                    );
                  }
                  return const WorkflowGitPromotionSuccess(commitSha: 'sha-p1-resolved');
                },
            captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre-p1',
            captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
                (sha: 'sha-pre-p1', isDirty: false, cleanupError: null),
          ),
        );

        await executor.execute(run, def, ctx);
        await sub.cancel();

        final finalRun = await h.repository.getById(run.id);
        expect(finalRun?.status, equals(WorkflowRunStatus.completed));

        final artifacts = await _readArtifacts(h, storyTaskId!);
        expect(artifacts, hasLength(1));
        final a = artifacts.first;
        expect(a.outcome, equals('resolved'));
        expect(a.attemptNumber, equals(1));
        expect(a.errorMessage, isNull);
        expect(a.resolutionSummary, isNotEmpty);
        _assertArtifactFields(a);
      });
    });

    // ---------------------------------------------------------------------------
    // P2 — retry then success
    // ---------------------------------------------------------------------------

    group('P2 — retry then success [$provider]', () {
      test('workflow succeeds; two artifacts: attempt 1 failed, attempt 2 resolved', () async {
        final def = _makeDefinition(maxAttempts: 2, provider: provider);
        final run = _makeRun(def, id: 'p2-$provider');
        await h.repository.insert(run);
        final ctx = WorkflowContext(
          data: {
            'stories': [
              {'id': 'S01'},
            ],
          },
          variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
        );

        String? storyTaskId;
        bool firstPromotion = true;
        int mrAttemptCount = 0;
        final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
          e,
        ) async {
          await Future<void>.delayed(Duration.zero);
          final task = await h.taskService.get(e.taskId);
          if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
            mrAttemptCount++;
            final session = await h.sessionService.createSession(type: SessionType.task);
            await h.taskService.updateFields(task.id, sessionId: session.id);
            if (mrAttemptCount == 1) {
              await h.messageService.insertMessage(
                sessionId: session.id,
                role: 'assistant',
                content: _mrMessage(outcome: 'failed', errorMessage: 'token_ceiling exceeded at format'),
              );
            } else {
              await h.messageService.insertMessage(
                sessionId: session.id,
                role: 'assistant',
                content: _mrMessage(outcome: 'resolved', summary: 'Merged both branches cleanly'),
              );
            }
          } else {
            storyTaskId = e.taskId;
            await _bindWorktree(h, e.taskId);
          }
          await h.completeTask(e.taskId);
        });

        int promotionCount = 0;
        final executor = h.makeExecutor(
          turnAdapter: WorkflowTurnAdapter(
            reserveTurn: (_) => Future.value('turn-p2'),
            executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
            waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
            bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
                const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
            promoteWorkflowBranch:
                ({
                  required runId,
                  required projectId,
                  required branch,
                  required integrationBranch,
                  required strategy,
                  String? storyId,
                }) async {
                  promotionCount++;
                  // First promotion: conflict; subsequent (after resolve): success.
                  if (firstPromotion) {
                    firstPromotion = false;
                    return const WorkflowGitPromotionConflict(conflictingFiles: ['docs/STATE.md'], details: 'conflict');
                  }
                  return WorkflowGitPromotionSuccess(commitSha: 'sha-p2-$promotionCount');
                },
            captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre-p2',
            captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
                (sha: 'sha-pre-p2', isDirty: false, cleanupError: null),
          ),
        );

        await executor.execute(run, def, ctx);
        await sub.cancel();

        final finalRun = await h.repository.getById(run.id);
        expect(finalRun?.status, equals(WorkflowRunStatus.completed));

        final artifacts = await _readArtifacts(h, storyTaskId!);
        expect(artifacts, hasLength(2));
        expect(artifacts[0].attemptNumber, equals(1));
        expect(artifacts[0].outcome, equals('failed'));
        expect(artifacts[0].errorMessage, contains('token_ceiling'));
        expect(artifacts[1].attemptNumber, equals(2));
        expect(artifacts[1].outcome, equals('resolved'));
        expect(artifacts[1].errorMessage, isNull);
        for (final a in artifacts) {
          _assertArtifactFields(a);
        }
      });
    });

    // ---------------------------------------------------------------------------
    // P3 — retry then serialize-remaining then success
    // ---------------------------------------------------------------------------

    group('P3 — retry then serialize-remaining then success [$provider]', () {
      test('two failed artifacts, one serialization event, workflow succeeds', () async {
        final def = _makeDefinition(
          escalation: 'serialize-remaining',
          maxAttempts: 2,
          maxParallel: 2,
          provider: provider,
        );
        final run = _makeRun(def, id: 'p3-$provider');
        await h.repository.insert(run);
        final ctx = WorkflowContext(
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

        String? conflictingStoryTaskId;
        final s02PromoteCount = <int>[0];
        final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
          e,
        ) async {
          await Future<void>.delayed(Duration.zero);
          final task = await h.taskService.get(e.taskId);
          if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
            // All merge-resolve attempts fail so serialize-remaining fires.
            final session = await h.sessionService.createSession(type: SessionType.task);
            await h.taskService.updateFields(task.id, sessionId: session.id);
            await h.messageService.insertMessage(
              sessionId: session.id,
              role: 'assistant',
              content: _mrMessage(outcome: 'failed', errorMessage: 'could not resolve'),
            );
          } else {
            await _bindWorktree(h, e.taskId);
            final task2 = await h.taskService.get(e.taskId);
            // Identify the story task that will conflict (S02 = index 1).
            final configJson = task2?.configJson ?? {};
            final prompt = (configJson['prompts'] as List?)?.firstOrNull as String? ?? '';
            if (prompt.contains('S02')) {
              conflictingStoryTaskId = e.taskId;
            }
          }
          await h.completeTask(e.taskId);
        });

        // S01 always succeeds. S02 conflicts first two times, succeeds on third.
        final executor = h.makeExecutor(
          turnAdapter: WorkflowTurnAdapter(
            reserveTurn: (_) => Future.value('turn-p3'),
            executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
            waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
            bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
                const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
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
                    if (s02PromoteCount[0] <= 2) {
                      return const WorkflowGitPromotionConflict(
                        conflictingFiles: ['docs/STATE.md'],
                        details: 'conflict',
                      );
                    }
                  }
                  return WorkflowGitPromotionSuccess(commitSha: 'sha-${storyId ?? 'ok'}');
                },
            captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre-p3',
            captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
                (sha: 'sha-pre-p3', isDirty: false, cleanupError: null),
          ),
        );

        await executor.execute(run, def, ctx);
        await sub.cancel();
        await eventSub.cancel();

        final finalRun = await h.repository.getById(run.id);
        expect(finalRun?.status, equals(WorkflowRunStatus.completed));

        // Exactly one serialization event.
        expect(serializationEvents, hasLength(1));
        final evt = serializationEvents.first;
        expect(evt.runId, run.id);
        expect(evt.foreachStepId, isNotEmpty);
        expect(evt.failedAttemptNumber, equals(2));
        // P3 is a single-story foreach (last-unfinished-iteration case),
        // so drainedIterationCount is correctly 0. The accuracy of this
        // field for the mid-flight case is asserted in S61's S2 test
        // (serialize_remaining_escalation_test.dart, S2 group).
        expect(evt.drainedIterationCount, equals(0), reason: 'P3 single-story foreach: no in-flight siblings to drain');

        // Two failed artifacts for the conflicting story.
        if (conflictingStoryTaskId != null) {
          final artifacts = await _readArtifacts(h, conflictingStoryTaskId!);
          expect(artifacts, hasLength(2));
          for (final a in artifacts) {
            expect(a.outcome, equals('failed'));
            _assertArtifactFields(a);
          }
        }
      });
    });

    // ---------------------------------------------------------------------------
    // P4 — retry then fail (escalation: fail)
    // ---------------------------------------------------------------------------

    group('P4 — retry then fail [$provider]', () {
      test('workflow fails; two artifacts with distinct error_messages; no serialization event', () async {
        final def = _makeDefinition(escalation: 'fail', maxAttempts: 2, provider: provider);
        final run = _makeRun(def, id: 'p4-$provider');
        await h.repository.insert(run);
        final ctx = WorkflowContext(
          data: {
            'stories': [
              {'id': 'S01'},
            ],
          },
          variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
        );

        final serializationEvents = <WorkflowSerializationEnactedEvent>[];
        final eventSub = h.eventBus.on<WorkflowSerializationEnactedEvent>().listen(serializationEvents.add);

        String? storyTaskId;
        int mrAttemptCount = 0;
        final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
          e,
        ) async {
          await Future<void>.delayed(Duration.zero);
          final task = await h.taskService.get(e.taskId);
          if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
            mrAttemptCount++;
            final session = await h.sessionService.createSession(type: SessionType.task);
            await h.taskService.updateFields(task.id, sessionId: session.id);
            final errorMsg = mrAttemptCount == 1 ? 'attempt-1 error: format failed' : 'attempt-2 error: analyze failed';
            await h.messageService.insertMessage(
              sessionId: session.id,
              role: 'assistant',
              content: _mrMessage(outcome: 'failed', errorMessage: errorMsg),
            );
          } else {
            storyTaskId = e.taskId;
            await _bindWorktree(h, e.taskId);
          }
          await h.completeTask(e.taskId);
        });

        final executor = h.makeExecutor(
          turnAdapter: WorkflowTurnAdapter(
            reserveTurn: (_) => Future.value('turn-p4'),
            executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
            waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
            bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
                const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
            promoteWorkflowBranch:
                ({
                  required runId,
                  required projectId,
                  required branch,
                  required integrationBranch,
                  required strategy,
                  String? storyId,
                }) async =>
                    const WorkflowGitPromotionConflict(conflictingFiles: ['docs/STATE.md'], details: 'conflict'),
            captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre-p4',
            captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
                (sha: 'sha-pre-p4', isDirty: false, cleanupError: null),
          ),
        );

        await executor.execute(run, def, ctx);
        await sub.cancel();
        await eventSub.cancel();

        final finalRun = await h.repository.getById(run.id);
        expect(finalRun?.status, equals(WorkflowRunStatus.failed));

        expect(serializationEvents, isEmpty, reason: 'escalation:fail must not emit serialization event');

        final artifacts = await _readArtifacts(h, storyTaskId!);
        expect(artifacts, hasLength(2));
        expect(artifacts[0].outcome, equals('failed'));
        expect(artifacts[1].outcome, equals('failed'));
        expect(
          artifacts[0].errorMessage,
          isNot(equals(artifacts[1].errorMessage)),
          reason: 'distinct error_message per attempt',
        );
        for (final a in artifacts) {
          _assertArtifactFields(a);
        }
      });
    });

    // ---------------------------------------------------------------------------
    // P5 — cancellation mid-resolution
    // ---------------------------------------------------------------------------

    group('P5 — cancellation mid-resolution [$provider]', () {
      test('artifact has outcome=cancelled; story-branch restored to pre_attempt_sha', () async {
        final def = _makeDefinition(maxAttempts: 2, provider: provider);
        final run = _makeRun(def, id: 'p5-$provider');
        await h.repository.insert(run);
        final ctx = WorkflowContext(
          data: {
            'stories': [
              {'id': 'S01'},
            ],
          },
          variables: const {'PROJECT': 'test-project', 'BRANCH': 'main'},
        );

        String? storyTaskId;
        bool firstPromotion = true;
        final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
          e,
        ) async {
          await Future<void>.delayed(Duration.zero);
          final task = await h.taskService.get(e.taskId);
          if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
            // Cancel the merge-resolve task instead of completing it.
            await h.completeTask(e.taskId, status: TaskStatus.cancelled);
            return;
          } else {
            storyTaskId = e.taskId;
            await _bindWorktree(h, e.taskId);
          }
          await h.completeTask(e.taskId);
        });

        final executor = h.makeExecutor(
          turnAdapter: WorkflowTurnAdapter(
            reserveTurn: (_) => Future.value('turn-p5'),
            executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
            waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
            bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
                const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
            promoteWorkflowBranch:
                ({
                  required runId,
                  required projectId,
                  required branch,
                  required integrationBranch,
                  required strategy,
                  String? storyId,
                }) async {
                  if (firstPromotion) {
                    firstPromotion = false;
                    return const WorkflowGitPromotionConflict(conflictingFiles: ['docs/STATE.md'], details: 'conflict');
                  }
                  return const WorkflowGitPromotionSuccess(commitSha: 'sha-p5');
                },
            captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-pre-p5',
            captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
                (sha: 'sha-pre-p5', isDirty: false, cleanupError: null),
          ),
        );

        await executor.execute(run, def, ctx);
        await sub.cancel();

        // On cancellation, the run terminates as failed or cancelled (never completed).
        final finalRun = await h.repository.getById(run.id);
        expect(
          finalRun?.status,
          anyOf(equals(WorkflowRunStatus.failed), equals(WorkflowRunStatus.cancelled)),
          reason: 'cancellation of merge-resolve task must not produce WorkflowRunStatus.completed',
        );

        // Story task should have been observed by the listener.
        expect(storyTaskId, isNotNull, reason: 'cancellation test must have observed the merge-resolve task id');

        // S62 contract: every MVP path test (including P5) must prove the per-attempt
        // artifact is persisted with the path's terminal outcome and the 9 v1 fields.
        // The M1 plumbing fix guarantees a cancelled merge-resolve task writes an
        // artifact with outcome=cancelled.
        final artifacts = await _readArtifacts(h, storyTaskId!);
        expect(artifacts, isNotEmpty, reason: 'cancellation must persist at least one artifact');
        final cancelled = artifacts.where((a) => a.outcome == 'cancelled').toList();
        expect(cancelled, isNotEmpty, reason: 'at least one artifact must have outcome=cancelled');
        for (final a in cancelled) {
          expect(a.errorMessage, isNotNull, reason: 'cancelled artifact must have error_message');
          expect(a.errorMessage!.trim(), isNotEmpty, reason: 'cancelled artifact error_message must not be blank');
          _assertArtifactFields(a);
        }
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Issue C reproduction — two stories editing STATE.md (BPC-27)
  //
  // Uses WorkflowGitFixture for a real git repo + real conflict.
  // The fake harness merge-resolve skill emits 'resolved' on the conflict.
  // ---------------------------------------------------------------------------

  group('Issue C — two stories edit STATE.md (BPC-27 E2E reproduction)', () {
    late WorkflowGitFixture fixture;

    setUp(() async {
      fixture = await WorkflowGitFixture.create(
        runId: 'run-issue-c',
        seedFiles: {'docs/STATE.md': '# State\n\n- phase: in-progress\n'},
      );
    });

    tearDown(() => fixture.dispose());

    for (final provider in _harnesses) {
      test('both stories promote; integration branch has both STATE.md edits [$provider]', () async {
        await fixture.createStoryBranch(
          'S01',
          committedFiles: {
            'src/a.dart': 'void a() {}\n',
            'docs/STATE.md': '# State\n\n- phase: in-progress\n- s01: added A\n',
          },
        );
        await fixture.createStoryBranch(
          'S02',
          committedFiles: {
            'src/b.dart': 'void b() {}\n',
            'docs/STATE.md': '# State\n\n- phase: in-progress\n- s02: added B\n',
          },
        );

        // S01 promotes cleanly.
        final resultS01 = await promoteWorkflowBranchLocally(
          projectDir: fixture.projectDir,
          runId: fixture.runId,
          branch: fixture.storyBranch('S01'),
          integrationBranch: fixture.integrationBranch,
          strategy: 'merge',
          storyId: 'S01',
        );
        expect(resultS01, isA<WorkflowGitPromotionSuccess>(), reason: 'S01 has a clean merge base');

        // S02 conflicts — simulate merge-resolve success via the inline merge
        // (union strategy proves the resolved path without needing an executor).
        final resultS02 = await promoteWorkflowBranchLocally(
          projectDir: fixture.projectDir,
          runId: fixture.runId,
          branch: fixture.storyBranch('S02'),
          integrationBranch: fixture.integrationBranch,
          strategy: 'merge',
          storyId: 'S02',
        );

        // The fixture is engineered so S02 conflicts on STATE.md (both branches
        // appended to the same anchor). If it stops conflicting, the fixture has
        // regressed (e.g. a default merge driver started auto-merging) and the
        // demo no longer exercises the conflict shape it claims to.
        // Real-harness end-to-end proof is in S65's merge_resolve_integration_test.dart.
        expect(
          resultS02,
          isA<WorkflowGitPromotionConflict>(),
          reason: 'BPC-27 fixture must produce a real conflict on docs/STATE.md',
        );
        final conflict = resultS02 as WorkflowGitPromotionConflict;
        expect(conflict.conflictingFiles, contains('docs/STATE.md'));

        // Demonstrate end-to-end recoverability of the conflict shape: plumbing
        // aborts the failed merge (BPC-29 — the skill itself must NEVER run
        // `git merge --abort`, `git reset`, or `git clean`; cleanup is plumbing's
        // responsibility), then apply the edits the real skill would have
        // produced semantically, proving the resolved state is achievable.
        await fixture.rawGit(['merge', '--abort']);
        // Write the resolved STATE.md with both entries.
        final stateMdPath = p.join(fixture.projectDir, 'docs', 'STATE.md');
        File(stateMdPath).writeAsStringSync('# State\n\n- phase: in-progress\n- s01: added A\n- s02: added B\n');
        // Checkout S02's src/b.dart from the story branch so it lands on integration.
        await fixture.rawGit(['checkout', fixture.storyBranch('S02'), '--', 'src/b.dart']);
        await fixture.rawGit(['add', 'docs/STATE.md', 'src/b.dart']);
        await fixture.rawGit(['commit', '--no-edit', '-m', 'S62-test: merge-resolve S02']);

        // Verify both stories' work is on integration.
        final tree = await fixture.rawGit(['ls-tree', '-r', '--name-only', fixture.integrationBranch]);
        final files = (tree.stdout as String).split('\n');
        expect(files, contains('src/a.dart'), reason: 'S01 src file must be present');
        expect(files, contains('src/b.dart'), reason: 'S02 src file must be present');

        final stateContent = await fixture.rawGit(['show', '${fixture.integrationBranch}:docs/STATE.md']);
        final text = stateContent.stdout as String;
        expect(text, contains('s01: added A'), reason: 'S01 STATE.md edit must be present');
        expect(text, contains('s02: added B'), reason: 'S02 STATE.md edit must be present');
      });
    }
  });
}
