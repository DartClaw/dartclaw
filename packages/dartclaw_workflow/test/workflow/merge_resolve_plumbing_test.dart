// Component tests for the S60 merge-resolve retry loop plumbing.
//
// Covers: happy path (retry-then-success), max-attempts exhaustion with
// escalation:fail, enabled:false byte-identity, crash recovery artifact
// (BPC-20), cancellation mid-attempt, cleanup failure handling, and
// artifact filename scoping (CRITICAL 3).
@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart'
    show
        MergeResolveConfig,
        MergeResolveEscalation,
        SessionType,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy;
import 'package:path/path.dart' as p;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        MergeResolveAttemptArtifact,
        TaskArtifact,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitBootstrapResult,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionSuccess,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        kWorkflowContextClose,
        kWorkflowContextOpen;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a WorkflowDefinition with a foreach controller + child step and merge-resolve enabled.
///
/// The controller step (type:'foreach') routes through _executeForeachStep which
/// contains the merge-resolve retry loop. Plain mapOver steps use _executeMapStep
/// which does not have merge-resolve wired.
WorkflowDefinition _mergeResolveDef({
  int maxAttempts = 2,
  MergeResolveEscalation escalation = MergeResolveEscalation.fail,
}) {
  return WorkflowDefinition(
    name: 'mr-test',
    description: 'merge-resolve plumbing test',
    gitStrategy: WorkflowGitStrategy(
      bootstrap: true,
      worktree: const WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
      promotion: 'squash',
      mergeResolve: MergeResolveConfig(
        enabled: true,
        maxAttempts: maxAttempts,
        escalation: escalation,
        tokenCeiling: 10000,
      ),
    ),
    steps: const [
      WorkflowStep(
        id: 'stories-pipeline',
        name: 'Stories Pipeline',
        type: 'foreach',
        mapOver: 'stories',
        foreachSteps: ['impl'],
        maxParallel: 1,
      ),
      WorkflowStep(
        id: 'impl',
        name: 'Implement',
        type: 'coding',
        project: 'proj1',
        prompts: ['Implement {{map.item.id}}'],
      ),
    ],
  );
}

/// Builds a workflow-context assistant message payload with merge-resolve outputs.
String _mergeResolveMessage({
  String outcome = 'resolved',
  List<String> conflictedFiles = const ['lib/foo.dart'],
  String summary = 'resolved conflicts',
  String errorMessage = '',
}) {
  final payload = <String, dynamic>{
    'merge_resolve.outcome': outcome,
    'merge_resolve.conflicted_files': conflictedFiles,
    'merge_resolve.resolution_summary': summary,
    if (errorMessage.isNotEmpty) 'merge_resolve.error_message': errorMessage,
  };
  return '$kWorkflowContextOpen${jsonEncode(payload)}$kWorkflowContextClose';
}

/// Sets worktreeJson on [taskId] to simulate a per-map-item worktree binding.
Future<void> _bindWorktree(WorkflowExecutorHarness h, String taskId, String tempDirPath) async {
  await h.taskService.updateFields(taskId, worktreeJson: {
    'path': p.join(tempDirPath, 'worktrees', taskId),
    'branch': 'story-$taskId',
    'createdAt': DateTime.now().toIso8601String(),
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  // ---------------------------------------------------------------------------
  // BPC-31: enabled:false is byte-identical to pre-feature behavior
  // ---------------------------------------------------------------------------

  test('enabled:false — no merge-resolve tasks fired on conflict', () async {
    final def = WorkflowDefinition(
      name: 'mr-disabled',
      description: 'disabled merge resolve',
      gitStrategy: const WorkflowGitStrategy(
        bootstrap: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        promotion: 'squash',
        mergeResolve: MergeResolveConfig(enabled: false),
      ),
      steps: const [
        WorkflowStep(
          id: 'stories-pipeline',
          name: 'Stories Pipeline',
          type: 'foreach',
          mapOver: 'stories',
          foreachSteps: ['impl'],
          maxParallel: 1,
        ),
        WorkflowStep(
          id: 'impl',
          name: 'Implement',
          type: 'coding',
          project: 'proj1',
          prompts: ['Implement {{map.item.id}}'],
        ),
      ],
    );

    final run = WorkflowRun(
      id: 'run-disabled',
      definitionName: def.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
      definitionJson: def.toJson(),
    );
    await h.repository.insert(run);
    final context = WorkflowContext(data: {
      'stories': [
        {'id': 'S01'},
      ],
    }, variables: const {'PROJECT': 'proj1', 'BRANCH': 'main'});

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      taskCount++;
      await _bindWorktree(h, e.taskId, h.tempDir.path);
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    final executor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-0'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration'),
        promoteWorkflowBranch:
            ({required runId, required projectId, required branch, required integrationBranch, required strategy, String? storyId}) async =>
                const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict'),
      ),
    );

    await executor.execute(run, def, context);
    await sub.cancel();

    // Only the story task fires — no merge-resolve re-attempt tasks.
    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById(run.id);
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  // ---------------------------------------------------------------------------
  // Happy path: conflict → merge-resolve task → resolved → success
  // ---------------------------------------------------------------------------

  test('retry-then-success — one conflict, one merge-resolve task, promotion succeeds', () async {
    final def = _mergeResolveDef(maxAttempts: 2);
    final run = WorkflowRun(
      id: 'run-happy',
      definitionName: def.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
      definitionJson: def.toJson(),
    );
    await h.repository.insert(run);
    final context = WorkflowContext(data: {
      'stories': [
        {'id': 'S01'},
      ],
    }, variables: const {'PROJECT': 'proj1', 'BRANCH': 'main'});

    var taskCount = 0;
    String? firstTaskId;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      taskCount++;
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
        // Merge-resolve skill task — inject resolved outcome.
        final session = await h.sessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(task.id, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: _mergeResolveMessage(outcome: 'resolved'),
        );
      } else {
        // Story task — bind worktree.
        firstTaskId = e.taskId;
        await _bindWorktree(h, e.taskId, h.tempDir.path);
      }
      await h.completeTask(e.taskId);
    });

    bool firstPromotion = true;
    final executor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-happy'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration'),
        promoteWorkflowBranch:
            ({required runId, required projectId, required branch, required integrationBranch, required strategy, String? storyId}) async {
              if (firstPromotion) {
                firstPromotion = false;
                return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict');
              }
              return const WorkflowGitPromotionSuccess(commitSha: 'abc123');
            },
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha001',
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
            (sha: 'sha001', isDirty: false, cleanupError: null),
      ),
    );

    await executor.execute(run, def, context);
    await sub.cancel();

    // 1 story task + 1 merge-resolve skill task.
    expect(taskCount, equals(2));
    final finalRun = await h.repository.getById(run.id);
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));

    // Artifact written with correct filename scope.
    final artifacts = firstTaskId != null ? await h.taskRepository.listArtifactsByTask(firstTaskId!) : <TaskArtifact>[];
    final mrArtifacts = artifacts.where((a) => a.name.startsWith('merge_resolve_iter_'));
    expect(mrArtifacts, isNotEmpty, reason: 'artifact filename must include iter prefix');
    expect(mrArtifacts.first.name, contains('_iter_'));
    expect(mrArtifacts.first.name, contains('_attempt_'));

    // Verify artifact content.
    final artifactFile = File(mrArtifacts.first.path);
    expect(await artifactFile.exists(), isTrue);
    final artifactJson = jsonDecode(await artifactFile.readAsString()) as Map<String, dynamic>;
    final artifact = MergeResolveAttemptArtifact.fromJson(artifactJson);
    expect(artifact.outcome, equals('resolved'));
    expect(artifact.iterationIndex, equals(0));
    expect(artifact.attemptNumber, equals(1));
    expect(artifact.startedAt, isNotNull, reason: 'started_at must be populated');
    expect(artifact.elapsedMs, isNotNull, reason: 'elapsed_ms must be populated');
  });

  // ---------------------------------------------------------------------------
  // Max attempts exhausted with escalation:fail
  // ---------------------------------------------------------------------------

  test('max_attempts exhausted — escalation:fail returns conflict and persists artifacts per attempt', () async {
    final def = _mergeResolveDef(maxAttempts: 2, escalation: MergeResolveEscalation.fail);
    final run = WorkflowRun(
      id: 'run-exhaust',
      definitionName: def.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
      definitionJson: def.toJson(),
    );
    await h.repository.insert(run);
    final context = WorkflowContext(data: {
      'stories': [
        {'id': 'S01'},
      ],
    }, variables: const {'PROJECT': 'proj1', 'BRANCH': 'main'});

    var taskCount = 0;
    String? storyTaskId;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      taskCount++;
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
        final session = await h.sessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(task.id, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: _mergeResolveMessage(outcome: 'failed', errorMessage: 'agent gave up'),
        );
      } else {
        storyTaskId = e.taskId;
        await _bindWorktree(h, e.taskId, h.tempDir.path);
      }
      await h.completeTask(e.taskId);
    });

    final executor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-exhaust'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration'),
        promoteWorkflowBranch:
            ({required runId, required projectId, required branch, required integrationBranch, required strategy, String? storyId}) async =>
                const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict'),
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-exhaust',
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
            (sha: 'sha-exhaust', isDirty: false, cleanupError: null),
      ),
    );

    await executor.execute(run, def, context);
    await sub.cancel();

    // 1 story task + 2 merge-resolve tasks (maxAttempts=2).
    expect(taskCount, equals(3));
    final finalRun = await h.repository.getById(run.id);
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));

    // Two artifacts written, one per attempt, each with distinct filename.
    final artifacts = storyTaskId != null ? await h.taskRepository.listArtifactsByTask(storyTaskId!) : <TaskArtifact>[];
    final mrArtifacts = artifacts.where((a) => a.name.startsWith('merge_resolve_iter_')).toList();
    expect(mrArtifacts, hasLength(2), reason: 'one artifact per attempt');
    expect(mrArtifacts.map((a) => a.name).toSet(), hasLength(2), reason: 'artifact names must be unique');
    for (final a in mrArtifacts) {
      expect(a.name, matches(RegExp(r'merge_resolve_iter_\d+_attempt_\d+\.json')));
    }
  });

  // ---------------------------------------------------------------------------
  // Crash recovery — BPC-20 "interrupted by server restart"
  // ---------------------------------------------------------------------------

  test('crash recovery — persists artifact with BPC-20 error message on resume', () async {
    final def = _mergeResolveDef(maxAttempts: 3);

    // Pre-seed context to simulate a crash after attempt 1 — sha is persisted,
    // counter is 1 (meaning attempt 1 was in-flight when server died).
    // The state prefix is '_merge_resolve.<controllerStepId>.<iterIndex>',
    // where controllerStepId is 'stories-pipeline' (the foreach controller).
    final run = WorkflowRun(
      id: 'run-crash',
      definitionName: def.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
      contextJson: {
        'data': {
          '_merge_resolve.stories-pipeline.0.pre_attempt_sha': 'sha-crash',
          '_merge_resolve.stories-pipeline.0.attempt_counter': 1,
        },
      },
      definitionJson: def.toJson(),
    );
    await h.repository.insert(run);
    final context = WorkflowContext(
      data: {
        'stories': [
          {'id': 'S01'},
        ],
        '_merge_resolve.stories-pipeline.0.pre_attempt_sha': 'sha-crash',
        '_merge_resolve.stories-pipeline.0.attempt_counter': 1,
      },
      variables: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
    );

    String? storyTaskId;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
        final session = await h.sessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(task.id, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: _mergeResolveMessage(outcome: 'resolved'),
        );
      } else {
        storyTaskId = e.taskId;
        await _bindWorktree(h, e.taskId, h.tempDir.path);
      }
      await h.completeTask(e.taskId);
    });

    // First promotion returns conflict to enter the merge-resolve loop.
    // Inside the loop, crash recovery detects the in-flight attempt (counter=1)
    // and writes the crash artifact. Then the merge-resolve skill runs and resolves,
    // and the second promotion call succeeds.
    bool firstPromotion = true;
    final executor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-crash'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration'),
        promoteWorkflowBranch:
            ({required runId, required projectId, required branch, required integrationBranch, required strategy, String? storyId}) async {
              if (firstPromotion) {
                firstPromotion = false;
                return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/crash.dart'], details: 'crash conflict');
              }
              return const WorkflowGitPromotionSuccess(commitSha: 'crash-resolved');
            },
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-crash',
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
            (sha: 'sha-crash', isDirty: false, cleanupError: null),
      ),
    );

    await executor.execute(run, def, context);
    await sub.cancel();

    // Crash artifact must exist for attempt 1 (the in-flight one at restart).
    final artifacts = storyTaskId != null ? await h.taskRepository.listArtifactsByTask(storyTaskId!) : <TaskArtifact>[];
    final crashArtifacts = artifacts.where((a) => a.name.startsWith('merge_resolve_iter_0_attempt_1')).toList();
    expect(crashArtifacts, isNotEmpty, reason: 'crash artifact must be written for in-flight attempt');

    final crashArtifactFile = File(crashArtifacts.first.path);
    expect(await crashArtifactFile.exists(), isTrue);
    final decoded = jsonDecode(await crashArtifactFile.readAsString()) as Map<String, dynamic>;
    final crashArtifact = MergeResolveAttemptArtifact.fromJson(decoded);
    expect(crashArtifact.errorMessage, equals('interrupted by server restart'), reason: 'BPC-20 exact string required');
    expect(crashArtifact.outcome, equals('failed'));
  });

  // ---------------------------------------------------------------------------
  // Cancellation mid-attempt
  // ---------------------------------------------------------------------------

  test('cancellation mid-attempt — run fails, no further attempts launched', () async {
    final def = _mergeResolveDef(maxAttempts: 3);
    final run = WorkflowRun(
      id: 'run-cancel',
      definitionName: def.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
      definitionJson: def.toJson(),
    );
    await h.repository.insert(run);
    final context = WorkflowContext(data: {
      'stories': [
        {'id': 'S01'},
      ],
    }, variables: const {'PROJECT': 'proj1', 'BRANCH': 'main'});

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      taskCount++;
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
        await h.completeTask(e.taskId, status: TaskStatus.cancelled);
      } else {
        await _bindWorktree(h, e.taskId, h.tempDir.path);
        await h.completeTask(e.taskId);
      }
    });

    bool firstPromotion = true;
    final executor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-cancel'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration'),
        promoteWorkflowBranch:
            ({required runId, required projectId, required branch, required integrationBranch, required strategy, String? storyId}) async {
              if (firstPromotion) {
                firstPromotion = false;
                return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict');
              }
              return const WorkflowGitPromotionSuccess(commitSha: 'should-not-reach');
            },
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-cancel',
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
            (sha: 'sha-cancel', isDirty: false, cleanupError: null),
      ),
    );

    await executor.execute(run, def, context);
    await sub.cancel();

    // 1 story task + 1 merge-resolve skill task (cancelled); no further retry.
    expect(taskCount, equals(2));
    final finalRun = await h.repository.getById(run.id);
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  // ---------------------------------------------------------------------------
  // Pre-attempt cleanup failure — synthetic artifact persisted (HIGH 7)
  // ---------------------------------------------------------------------------

  test('pre-attempt cleanup failure — synthetic artifact with outcome:failed is written', () async {
    final def = _mergeResolveDef(maxAttempts: 2);
    final run = WorkflowRun(
      id: 'run-cleanup-fail',
      definitionName: def.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
      definitionJson: def.toJson(),
    );
    await h.repository.insert(run);
    final context = WorkflowContext(data: {
      'stories': [
        {'id': 'S01'},
      ],
    }, variables: const {'PROJECT': 'proj1', 'BRANCH': 'main'});

    var taskCount = 0;
    String? storyTaskId;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      taskCount++;
      await Future<void>.delayed(Duration.zero);
      storyTaskId = e.taskId;
      await _bindWorktree(h, e.taskId, h.tempDir.path);
      await h.completeTask(e.taskId);
    });

    final executor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-cleanup'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration'),
        promoteWorkflowBranch:
            ({required runId, required projectId, required branch, required integrationBranch, required strategy, String? storyId}) async =>
                const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict'),
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-cleanup',
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
            (sha: 'sha-cleanup', isDirty: true, cleanupError: 'cleanup failed: git reset --hard exit=1'),
      ),
    );

    await executor.execute(run, def, context);
    await sub.cancel();

    // Only 1 story task (no merge-resolve skill task — cleanup failed before invocation).
    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById(run.id);
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));

    final artifacts = storyTaskId != null ? await h.taskRepository.listArtifactsByTask(storyTaskId!) : <TaskArtifact>[];
    final mrArtifacts = artifacts.where((a) => a.name.startsWith('merge_resolve_iter_'));
    expect(mrArtifacts, isNotEmpty, reason: 'synthetic artifact must be written on cleanup failure');

    final artifactFile = File(mrArtifacts.first.path);
    final decoded = jsonDecode(await artifactFile.readAsString()) as Map<String, dynamic>;
    final artifact = MergeResolveAttemptArtifact.fromJson(decoded);
    expect(artifact.outcome, equals('failed'));
    expect(artifact.errorMessage, contains('cleanup failed'));
  });

  // ---------------------------------------------------------------------------
  // Artifact filename scoping — iterIndex in name (CRITICAL 3)
  // ---------------------------------------------------------------------------

  test('artifact filename includes iter-index to avoid collisions across stories', () async {
    final def = _mergeResolveDef(maxAttempts: 1);
    final run = WorkflowRun(
      id: 'run-filename',
      definitionName: def.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'proj1', 'BRANCH': 'main'},
      definitionJson: def.toJson(),
    );
    await h.repository.insert(run);
    final context = WorkflowContext(data: {
      'stories': [
        {'id': 'S01'},
        {'id': 'S02'},
      ],
    }, variables: const {'PROJECT': 'proj1', 'BRANCH': 'main'});

    int promoteCallCount = 0;
    final allStoryTaskIds = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task != null && task.configJson.containsKey('_workflowMergeResolveEnv')) {
        final session = await h.sessionService.createSession(type: SessionType.task);
        await h.taskService.updateFields(task.id, sessionId: session.id);
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: _mergeResolveMessage(outcome: 'resolved'),
        );
      } else {
        allStoryTaskIds.add(e.taskId);
        await _bindWorktree(h, e.taskId, h.tempDir.path);
      }
      await h.completeTask(e.taskId);
    });

    final executor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-fn'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration'),
        promoteWorkflowBranch:
            ({required runId, required projectId, required branch, required integrationBranch, required strategy, String? storyId}) async {
              promoteCallCount++;
              // Return conflict on first promotion call per story (odd calls), success on even.
              if (promoteCallCount.isOdd) {
                return const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict');
              }
              return const WorkflowGitPromotionSuccess(commitSha: 'abc');
            },
        captureWorkflowBranchSha: ({required projectId, required branch}) async => 'sha-fn',
        captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async =>
            (sha: 'sha-fn', isDirty: false, cleanupError: null),
      ),
    );

    await executor.execute(run, def, context);
    await sub.cancel();

    // Collect all merge-resolve artifacts across story tasks.
    final allArtifacts = <TaskArtifact>[];
    for (final tid in allStoryTaskIds) {
      allArtifacts.addAll(await h.taskRepository.listArtifactsByTask(tid));
    }
    final mrArtifacts = allArtifacts.where((a) => a.name.startsWith('merge_resolve_iter_')).toList();
    expect(mrArtifacts.isNotEmpty, isTrue);

    // All artifact names must be unique (no collision across different iterIndex values).
    final names = mrArtifacts.map((a) => a.name).toList();
    expect(names.toSet().length, equals(names.length), reason: 'no duplicate artifact names');

    // Each artifact name must embed the iter index.
    for (final name in names) {
      expect(name, matches(RegExp(r'merge_resolve_iter_\d+_attempt_\d+\.json')));
    }
  });
}
