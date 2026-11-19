import 'dart:convert';
import 'dart:io';

import '../task/execution_surface.dart';
import '../task/host_worktree_git.dart';
import '../task/remote_push_service.dart'
    show gitBranchName, pinnedBranchPushArguments, redactGitDestination, resolveWorkflowPushDestination;

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ArtifactKind, RepoLock, Task, WorkflowTaskService;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show
        MergeConflict,
        MergeExecutor,
        MergeStrategy,
        MergeSuccess,
        PushAuthFailure,
        PushError,
        PushRejected,
        PushResult,
        PushSuccess;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        resolveIntegrationBranchName,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionHeld,
        WorkflowGitPromotionError,
        WorkflowGitPromotionResult,
        WorkflowGitPromotionSuccess,
        WorkflowPublishStatus,
        WorkflowGitPublishResult;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

part 'workflow_git_candidate.dart';

final _workflowGitRepoLock = RepoLock();
final _workflowGitSupportLog = Logger('WorkflowGitSupport');

Future<Set<String>> workflowPushedBranches(WorkflowTaskService taskService, List<Task> tasks) async {
  final branches = <String>{};
  for (final task in tasks) {
    final artifacts = await taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.kind == ArtifactKind.branch && artifact.path.trim().isNotEmpty) {
        branches.add(artifact.path.trim());
      }
    }
  }
  return branches;
}

Future<String?> restoreCheckoutBeforeWorkflowBranchDeletion({
  required String projectDir,
  required Set<String> workflowBranches,
  required String? restoreRef,
}) async {
  final current = await runGit(['symbolic-ref', '--quiet', '--short', 'HEAD'], workingDirectory: projectDir);
  if (current.exitCode != 0) return null;

  final currentBranch = (current.stdout as String).trim();
  if (currentBranch.isEmpty || !workflowBranches.contains(currentBranch)) return null;

  final target = restoreRef?.trim();
  if (target == null || target.isEmpty) {
    return 'project checkout is on workflow branch "$currentBranch" but no restore ref was available';
  }
  final safeTarget = normalizeGitRefOperand(target, label: 'workflow restore ref');
  if (target == currentBranch) {
    return 'project checkout is on workflow branch "$currentBranch" and restore ref points to the same branch';
  }

  final dirty = await runHostWorktreeGit(['status', '--porcelain', '--untracked-files=all'], projectDir: projectDir);
  if (dirty.exitCode != 0) {
    return 'failed to inspect project checkout before restoring from workflow branch "$currentBranch": '
        '${_processFailureDetail(dirty)}';
  }
  if ((dirty.stdout as String).trim().isNotEmpty) {
    return 'project checkout is on workflow branch "$currentBranch" with uncommitted changes; '
        'leaving checkout in place to avoid data loss';
  }

  final switched = await _switchToRestoreRef(projectDir: projectDir, target: safeTarget);
  if (switched.exitCode == 0) {
    _workflowGitSupportLog.info('Restored project checkout from workflow branch "$currentBranch" to "$target"');
    return null;
  }

  final stderr = (switched.stderr as String).trim();
  final stdout = (switched.stdout as String).trim();
  final detail = stderr.isNotEmpty ? stderr : stdout;
  return 'failed to restore project checkout from "$currentBranch" to "$target": $detail';
}

Future<ProcessResult> _switchToRestoreRef({required String projectDir, required String target}) async {
  final safeTarget = normalizeGitRefOperand(target, label: 'workflow restore ref');
  final direct = await runHostWorktreeGit(['switch', '--', safeTarget], projectDir: projectDir);
  if (direct.exitCode == 0) return direct;

  if (_isRemoteTrackingRef(safeTarget)) {
    return runHostWorktreeGit(['switch', '--detach', '--', safeTarget], projectDir: projectDir);
  }

  return direct;
}

bool _isRemoteTrackingRef(String ref) {
  return ref.startsWith('origin/') || ref.startsWith('refs/remotes/origin/');
}

String _processFailureDetail(ProcessResult result) {
  final stderr = (result.stderr as String).trim();
  final stdout = (result.stdout as String).trim();
  final detail = stderr.isNotEmpty ? stderr : stdout;
  return detail.isEmpty ? 'exit=${result.exitCode}' : 'exit=${result.exitCode}: $detail';
}

Future<ProcessResult> runWorkflowGitCommand(List<String> args, {required String workingDirectory}) {
  return runHostWorktreeGit(args, projectDir: workingDirectory);
}

String workflowGitFailureDetail(ProcessResult result) => _processFailureDetail(result);

Future<bool> workflowLocalRefExists(String workingDirectory, String ref) async {
  final safeRef = normalizeGitRefOperand(ref, label: 'workflow ref');
  final candidates = <String>{safeRef};
  if (!safeRef.startsWith('origin/') && !safeRef.startsWith('refs/')) {
    candidates.add('origin/$safeRef');
  }
  for (final candidate in candidates) {
    try {
      final result = await runGit(['rev-parse', '--verify', '--quiet', candidate], workingDirectory: workingDirectory);
      if (result.exitCode == 0) return true;
    } on ProcessException {
      return false;
    }
  }
  return false;
}

/// Whether a workflow's integration branch is cut from the project's *remote*
/// state rather than its local one.
///
/// True only for the connected lane against a remote-backed project, where the
/// project is remote-authoritative. The local posture — `localFallbackDir`
/// non-null, i.e. a run composed through `stageHeadless` against the invocation
/// repository — always cuts from the local ref: prefixing `origin/` there would
/// base every step on the last *pushed* commit, so a locally committed change
/// is invisible to the whole run and the step reports the file missing.
bool workflowBranchFollowsRemote({required String? localFallbackDir, required String projectRemoteUrl}) =>
    localFallbackDir == null && projectRemoteUrl.trim().isNotEmpty;

Future<void> ensureWorkflowLocalBranch({
  required String projectDir,
  required String branch,
  required String baseRef,
  bool remoteBacked = false,
}) async {
  final safeBranch = normalizeGitRefOperand(branch, label: 'workflow branch');
  final safeBaseRef = normalizeGitRefOperand(baseRef, label: 'workflow base ref');
  final normalizedBaseRef = remoteBacked && !safeBaseRef.startsWith('origin/') ? 'origin/$safeBaseRef' : safeBaseRef;
  final existing = await runGit(['rev-parse', '--verify', safeBranch], workingDirectory: projectDir);
  if (existing.exitCode == 0) {
    return;
  }
  final create = await runHostWorktreeGit(['branch', '--', safeBranch, normalizedBaseRef], projectDir: projectDir);
  if (create.exitCode != 0) {
    final stderr = (create.stderr as String).trim();
    throw StateError('Failed to create workflow branch "$safeBranch" from "$normalizedBaseRef": $stderr');
  }
}

class WorkflowGitCleanupPlan {
  final Set<String> worktreePaths;
  final Set<String> branches;

  const new({required this.worktreePaths, required this.branches});
}

WorkflowGitCleanupPlan buildWorkflowCleanupPlan(String runId, List<Task> runTasks) {
  final worktreePaths = <String>{};
  final branches = <String>{
    resolveIntegrationBranchName(runId, perMapItem: false),
    resolveIntegrationBranchName(runId, perMapItem: true),
  };

  for (final task in runTasks) {
    final worktree = task.worktreeJson;
    if (worktree == null) continue;
    final path = worktree['path'];
    final branch = worktree['branch'];
    if (path is String && path.trim().isNotEmpty) {
      worktreePaths.add(path.trim());
    }
    if (branch is String && branch.trim().isNotEmpty) {
      branches.add(branch.trim());
    }
  }

  return WorkflowGitCleanupPlan(worktreePaths: worktreePaths, branches: branches);
}

String _repoLockKey(String projectDir) {
  try {
    return Directory(projectDir).resolveSymbolicLinksSync();
  } on FileSystemException {
    return Directory(projectDir).absolute.path;
  }
}

/// Commits pending changes in the worktree that currently has [branch] checked
/// out, if such a worktree exists and has any unstaged or untracked changes.
Future<void> commitWorkflowWorktreeChangesIfNeeded({
  required String projectDir,
  required String branch,
  required String commitMessage,
  String? expectedTree,
}) async {
  final safeBranch = normalizeGitRefOperand(branch, label: 'workflow branch');
  final worktreePath = await _findWorktreePathForBranch(projectDir: projectDir, branch: safeBranch);
  if (worktreePath == null) {
    return;
  }

  final status = await runHostWorktreeGit(
    ['status', '--porcelain', '--untracked-files=all'],
    projectDir: projectDir,
    worktreePath: worktreePath,
  );
  if (status.exitCode != 0) {
    final stderr = (status.stderr as String).trim();
    throw StateError('Failed to inspect workflow worktree "$worktreePath": $stderr');
  }
  if ((status.stdout as String).trim().isEmpty) {
    return;
  }

  final add = await runHostWorktreeGit(['add', '-A'], projectDir: projectDir, worktreePath: worktreePath);
  if (add.exitCode != 0) {
    final stderr = (add.stderr as String).trim();
    throw StateError('Failed to stage workflow worktree changes in "$worktreePath": $stderr');
  }
  if (expectedTree != null && await _readGit(projectDir, ['write-tree'], worktreePath: worktreePath) != expectedTree) {
    throw StateError('Git staged a different tree for "$branch". Review and commit its changes before retrying.');
  }

  final commit = await runHostWorktreeGit(
    ['commit', '-m', commitMessage],
    projectDir: projectDir,
    worktreePath: worktreePath,
  );
  if (commit.exitCode != 0 && !_isNothingToCommit(commit)) {
    final stderr = (commit.stderr as String).trim();
    final stdout = (commit.stdout as String).trim();
    final detail = stderr.isNotEmpty ? stderr : stdout;
    throw StateError('Failed to commit workflow worktree changes in "$worktreePath": $detail');
  }
}

/// Runs the cleanup triple on [branch]'s worktree, inside the repo lock.
///
/// Sequence: `git merge --abort` (best-effort; log + continue on failure),
/// `git reset --hard <preAttemptSha>`, `git clean -fd`.
///
/// Returns null on success. Returns an error string when reset or clean fails.
Future<String?> cleanupWorktreeForRetry({
  required String projectDir,
  required String branch,
  required String preAttemptSha,
}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    return _cleanupWorktreeForRetryUnlocked(projectDir: projectDir, branch: branch, preAttemptSha: preAttemptSha);
  });
}

Future<String?> _cleanupWorktreeForRetryUnlocked({
  required String projectDir,
  required String branch,
  required String preAttemptSha,
}) async {
  final safeBranch = normalizeGitRefOperand(branch, label: 'workflow branch');
  final worktreePath = await _findWorktreePathForBranch(projectDir: projectDir, branch: safeBranch) ?? projectDir;

  // Best-effort: abort any in-progress merge; ignore failure.
  final abortResult = await runHostWorktreeGit(
    ['merge', '--abort'],
    projectDir: projectDir,
    worktreePath: worktreePath,
  );
  if (abortResult.exitCode != 0) {
    final detail = (abortResult.stderr as String).trim();
    if (detail.isNotEmpty && !detail.contains('There is no merge to abort') && !detail.contains('MERGE_HEAD')) {
      // Non-trivial abort failure; log but continue.
      stderr.writeln('[workflow-git] cleanup: merge --abort ignored: $detail');
    }
  }

  final resetResult = await runHostWorktreeGit(
    ['reset', '--hard', preAttemptSha],
    projectDir: projectDir,
    worktreePath: worktreePath,
  );
  if (resetResult.exitCode != 0) {
    final detail = (resetResult.stderr as String).trim();
    return 'cleanup failed: git reset --hard exit=${resetResult.exitCode} path=$worktreePath'
        '${detail.isEmpty ? '' : ': $detail'}';
  }

  final cleanResult = await runHostWorktreeGit(['clean', '-fd'], projectDir: projectDir, worktreePath: worktreePath);
  if (cleanResult.exitCode != 0) {
    final detail = (cleanResult.stderr as String).trim();
    return 'cleanup failed: git clean -fd exit=${cleanResult.exitCode} path=$worktreePath'
        '${detail.isEmpty ? '' : ': $detail'}';
  }

  return null;
}

/// Returns the current HEAD SHA of [branch] via `git rev-parse`, or null on failure.
Future<String?> captureWorkflowBranchSha({required String projectDir, required String branch}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    final safeBranch = normalizeGitRefOperand(branch, label: 'workflow branch');
    final result = await runGit(['rev-parse', safeBranch], workingDirectory: projectDir);
    if (result.exitCode != 0) return null;
    final sha = (result.stdout as String).trim();
    return sha.isNotEmpty ? sha : null;
  });
}

/// Result of [captureAndCleanWorktreeForRetry] — holds lock across SHA capture,
/// dirty check, and cleanup triple so no external mutation window exists.
final class CaptureAndCleanResult {
  final String? sha;
  final bool isDirty;
  final String? cleanupError;

  const new({required this.sha, required this.isDirty, this.cleanupError});
}

/// Under a single [_workflowGitRepoLock] scope:
///  1. Captures HEAD SHA of [branch] (returns null on failure).
///  2. Checks whether the worktree is dirty via `git status --porcelain`.
///  3. If dirty, runs the cleanup triple (merge-abort + reset + clean).
///
/// Returns a [CaptureAndCleanResult] with all three values.
Future<CaptureAndCleanResult> captureAndCleanWorktreeForRetry({
  required String projectDir,
  required String branch,
  String? preAttemptSha,
}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    final safeBranch = normalizeGitRefOperand(branch, label: 'workflow branch');
    final worktreePath = await _findWorktreePathForBranch(projectDir: projectDir, branch: safeBranch) ?? projectDir;

    final revResult = await runGit(['rev-parse', safeBranch], workingDirectory: projectDir);
    final sha = revResult.exitCode == 0 ? (revResult.stdout as String).trim() : null;

    final statusResult = await runHostWorktreeGit(
      ['status', '--porcelain', '--untracked-files=all'],
      projectDir: projectDir,
      worktreePath: worktreePath,
    );
    final isDirty = statusResult.exitCode == 0
        ? (statusResult.stdout as String).trim().isNotEmpty
        : true; // conservatively assume dirty on error

    if (!isDirty) return CaptureAndCleanResult(sha: sha?.isEmpty == true ? null : sha, isDirty: false);

    final effectiveSha = preAttemptSha ?? sha;
    if (effectiveSha == null || effectiveSha.isEmpty) {
      return CaptureAndCleanResult(
        sha: null,
        isDirty: true,
        cleanupError: 'cleanup failed: no SHA available for reset',
      );
    }

    final cleanupError = await _cleanupWorktreeForRetryUnlocked(
      projectDir: projectDir,
      branch: branch,
      preAttemptSha: effectiveSha,
    );
    return CaptureAndCleanResult(sha: sha?.isEmpty == true ? null : sha, isDirty: true, cleanupError: cleanupError);
  });
}

/// Holds [_workflowGitRepoLock] for the full duration of [body].
///
/// Used by the merge-resolve attempt loop to span one attempt's
/// `capture+clean → skill invocation → outcome read → promotion retry` chain
/// under a single lock so no concurrent sibling promotion can mutate the
/// integration branch mid-resolution.
///
/// Inner primitives in this file (e.g. [captureAndCleanWorktreeForRetry],
/// [promoteWorkflowBranchLocally]) that take the same lock continue to work
/// unchanged because [RepoLock] is reentrant within the same zone.
Future<T> runWorkflowGitResolverAttemptUnderLock<T>({required String projectDir, required Future<T> Function() body}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), body);
}

Future<WorkflowGitPromotionResult> promoteWorkflowBranchLocally({
  required String projectDir,
  required String runId,
  required String branch,
  required String integrationBranch,
  required String strategy,
  String? storyId,
  String? approvedCandidate,
}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    return _promoteWorkflowBranchLocallyUnlocked(
      projectDir: projectDir,
      runId: runId,
      branch: branch,
      integrationBranch: integrationBranch,
      strategy: strategy,
      storyId: storyId,
      approvedCandidate: approvedCandidate,
    );
  });
}

Future<WorkflowGitPromotionResult> _promoteWorkflowBranchLocallyUnlocked({
  required String projectDir,
  required String runId,
  required String branch,
  required String integrationBranch,
  required String strategy,
  String? storyId,
  String? approvedCandidate,
}) async {
  final safeBranch = gitBranchName(branch);
  final safeIntegrationBranch = gitBranchName(integrationBranch);
  final String sourceRevision;
  final String baseRevision;
  try {
    final candidate = await _inspectCandidate(
      projectDir: projectDir,
      branch: safeBranch,
      baseRef: safeIntegrationBranch,
      operation: ['promote', strategy],
      sweepBase: true,
    );
    if (candidate.requiresApproval(approvedCandidate)) {
      return WorkflowGitPromotionHeld(
        candidate.protectedPaths,
        candidate: candidate.identity,
        destination: safeIntegrationBranch,
        worktreePath: candidate.source.worktree,
        destinationWorktreePath: candidate.base.worktree,
      );
    }
    sourceRevision = await _sweepCandidateTree(
      projectDir: projectDir,
      branch: safeBranch,
      candidate: candidate.source,
      commitMessage: 'chore(workflow): ${storyId ?? runId} changes',
    );
    // Sweep pending changes in the integration worktree too. In inline mode
    // the integration branch is checked out in the project root while
    // upstream artifact-producing steps run
    // there; anything they wrote that the artifact committer did not add
    // (intermediate files, STATE/LEARNINGS edits, untracked research docs)
    // would leave a dirty index/tree and fail MergeExecutor's pre-merge
    // invariant check with "Merge requires a clean index". Committing the
    // leftover state now folds it into the integration history instead of
    // silently aborting promotion.
    baseRevision = await _sweepCandidateTree(
      projectDir: projectDir,
      branch: safeIntegrationBranch,
      candidate: candidate.base,
      commitMessage: 'chore(workflow): ${storyId ?? runId} integration cleanup',
    );
  } catch (error) {
    return WorkflowGitPromotionError(error.toString());
  }

  try {
    final mergeResult = await _withIntegrationWorktree(
      projectDir: projectDir,
      branch: safeIntegrationBranch,
      action: (integrationWorktreeDir) async {
        final mergeExecutor = MergeExecutor(
          projectDir: projectDir,
          worktreePath: integrationWorktreeDir,
          defaultStrategy: strategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
        );
        return mergeExecutor.merge(
          branch: sourceRevision,
          baseRef: safeIntegrationBranch,
          taskId: storyId ?? runId,
          taskTitle: storyId == null ? 'workflow promotion' : 'promote $storyId',
          expectedBaseSha: baseRevision,
          strategy: strategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
        );
      },
    );

    return switch (mergeResult) {
      MergeSuccess(:final commitSha) => WorkflowGitPromotionSuccess(commitSha: commitSha),
      MergeConflict(:final conflictingFiles, :final details) => WorkflowGitPromotionConflict(
        conflictingFiles: conflictingFiles,
        details: details,
      ),
    };
  } catch (error) {
    return WorkflowGitPromotionError(error.toString());
  }
}

Future<T> _withIntegrationWorktree<T>({
  required String projectDir,
  required String branch,
  required Future<T> Function(String worktreePath) action,
}) async {
  final safeBranch = normalizeGitRefOperand(branch, label: 'workflow branch');
  final existingWorktree = await _findWorktreePathForBranch(projectDir: projectDir, branch: safeBranch);
  if (existingWorktree != null) {
    return action(existingWorktree);
  }

  final tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_integration_');
  final worktreePath = p.join(tempDir.path, 'worktree');
  final add = await runHostWorktreeGit(['worktree', 'add', worktreePath, safeBranch], projectDir: projectDir);
  if (add.exitCode != 0) {
    final stderr = (add.stderr as String).trim();
    final stdout = (add.stdout as String).trim();
    final detail = stderr.isNotEmpty ? stderr : stdout;
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort cleanup; the add failure is the actionable error.
    }
    throw StateError('Failed to create temporary workflow integration worktree for "$branch": $detail');
  }

  try {
    return await action(worktreePath);
  } finally {
    await runHostWorktreeGit(['worktree', 'remove', '--force', worktreePath], projectDir: projectDir);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Git worktree cleanup already ran; leftover temp dirs are non-fatal.
      }
    }
  }
}

Future<WorkflowGitPublishResult> publishWorkflowBranchLocally({
  required String projectDir,
  required String branch,
  required String baseRef,
  String? approvedCandidate,
  String remote = 'origin',
}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    final safeBranch = gitBranchName(branch);
    final safeRemote = normalizeGitRefOperand(remote, label: 'workflow remote');
    final String? destination;
    try {
      destination = await resolveWorkflowPushDestination(workingDirectory: projectDir, remote: safeRemote);
    } catch (error) {
      return _publishFailure(safeBranch, safeRemote, 'Failed to inspect execution surface: $error');
    }
    return _publishWorkflowBranchUnlocked(
      projectDir: projectDir,
      branch: safeBranch,
      baseRef: baseRef,
      remote: safeRemote,
      destination: destination,
      approvedCandidate: approvedCandidate,
      pushBranch: (revision) async {
        final reviewedDestination = destination;
        if (reviewedDestination == null) return PushError('Remote "$safeRemote" has no push URL.');
        try {
          final current = await resolveWorkflowPushDestination(workingDirectory: projectDir, remote: safeRemote);
          if (current != reviewedDestination) return PushError('Remote "$safeRemote" changed after review.');
        } catch (error) {
          return const PushError('Failed to verify the reviewed push URL.');
        }
        final push = await runGit(
          pinnedBranchPushArguments(remote: safeRemote, branch: safeBranch, revision: revision),
          workingDirectory: projectDir,
        );
        return push.exitCode == 0
            ? const PushSuccess()
            : PushError(redactGitDestination(_processFailureDetail(push), reviewedDestination));
      },
      fetchRemoteTrackingRef: () =>
          _fetchRemoteTrackingRef(projectDir: projectDir, branch: safeBranch, remote: safeRemote),
    );
  });
}

WorkflowGitPublishResult _publishFailure(String branch, String remote, String error) => WorkflowGitPublishResult(
  status: WorkflowPublishStatus.failed,
  branch: branch,
  remote: remote,
  prUrl: '',
  error: error,
);

typedef WorkflowBranchPush = Future<PushResult> Function(String revision);
typedef WorkflowRemoteTrackingRefFetch = Future<ProcessResult> Function();

Future<WorkflowGitPublishResult> publishWorkflowBranchWithRemotePush({
  required String projectDir,
  required String branch,
  required String baseRef,
  String? approvedCandidate,
  String? destination,
  required WorkflowBranchPush pushBranch,
  WorkflowRemoteTrackingRefFetch? fetchRemoteTrackingRef,
  String remote = 'origin',
}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    return _publishWorkflowBranchUnlocked(
      projectDir: projectDir,
      branch: gitBranchName(branch),
      baseRef: baseRef,
      approvedCandidate: approvedCandidate,
      destination: destination,
      remote: normalizeGitRefOperand(remote, label: 'workflow remote'),
      pushBranch: pushBranch,
      fetchRemoteTrackingRef: fetchRemoteTrackingRef,
    );
  });
}

Future<WorkflowGitPublishResult> _publishWorkflowBranchUnlocked({
  required String projectDir,
  required String branch,
  required String baseRef,
  required String? approvedCandidate,
  required String? destination,
  required String remote,
  required WorkflowBranchPush pushBranch,
  required WorkflowRemoteTrackingRefFetch? fetchRemoteTrackingRef,
}) async {
  final _WorkflowGitCandidate candidate;
  final String safeBaseRef;
  try {
    safeBaseRef = normalizeGitRefOperand(baseRef, label: 'workflow base ref');
    candidate = await _inspectCandidate(
      projectDir: projectDir,
      branch: branch,
      baseRef: safeBaseRef,
      operation: ['publish', remote, destination],
    );
  } catch (error) {
    return _publishFailure(branch, remote, 'Failed to inspect execution surface: $error');
  }
  if (candidate.requiresApproval(approvedCandidate)) {
    return WorkflowGitPublishResult(
      status: WorkflowPublishStatus.held,
      branch: branch,
      remote: remote,
      prUrl: '',
      heldPaths: candidate.protectedPaths,
      heldCandidate: candidate.identity,
      heldDestination: '$remote/$branch',
      heldWorktreePath: candidate.source.worktree,
    );
  }
  final String revision;
  try {
    revision = await _sweepCandidateTree(
      projectDir: projectDir,
      branch: branch,
      candidate: candidate.source,
      commitMessage: 'workflow: prepare publish',
    );
    if (gitBranchName(safeBaseRef) != branch &&
        await _resolveCommit(projectDir, safeBaseRef) != candidate.base.revision) {
      throw StateError('Workflow base "$safeBaseRef" changed after inspection. Retry to review its current changes.');
    }
  } catch (error) {
    return _publishFailure(branch, remote, 'Failed to commit pending worktree changes before publish: $error');
  }

  switch (await pushBranch(revision)) {
    case PushSuccess():
      break;
    case PushAuthFailure(:final details):
      return _publishFailure(branch, remote, 'Authentication failed: $details');
    case PushRejected(:final reason):
      return _publishFailure(branch, remote, 'Remote rejected push: $reason');
    case PushError(:final message):
      return _publishFailure(branch, remote, 'Push failed: $message');
  }

  if (fetchRemoteTrackingRef != null) {
    final fetch = await fetchRemoteTrackingRef();
    if (fetch.exitCode != 0) {
      final detail = _processFailureDetail(fetch);
      return _publishFailure(
        branch,
        remote,
        'Failed to refresh remote-tracking ref: ${destination == null ? detail : redactGitDestination(detail, destination)}',
      );
    }
    try {
      if (await _resolveCommit(projectDir, 'refs/remotes/$remote/$branch') != revision) {
        return _publishFailure(
          branch,
          remote,
          'Remote-tracking ref refs/remotes/$remote/$branch differs from the pushed revision.',
        );
      }
    } catch (error) {
      return _publishFailure(
        branch,
        remote,
        'Push reported success but refs/remotes/$remote/$branch is unavailable locally: $error',
      );
    }
  }

  return WorkflowGitPublishResult(status: WorkflowPublishStatus.success, branch: branch, remote: remote, prUrl: '');
}

Future<ProcessResult> _fetchRemoteTrackingRef({
  required String projectDir,
  required String branch,
  required String remote,
}) {
  final safeBranch = normalizeGitRefOperand(branch, label: 'workflow branch');
  final remoteRef = 'refs/heads/$safeBranch:refs/remotes/$remote/$safeBranch';
  return runHostWorktreeGit(['fetch', '--no-tags', remote, remoteRef], projectDir: projectDir);
}

Future<String?> _findWorktreePathForBranch({required String projectDir, required String branch}) async {
  final result = await runGit(['worktree', 'list', '--porcelain', '-z'], workingDirectory: projectDir);
  if (result.exitCode != 0) {
    final stderr = (result.stderr as String).trim();
    throw StateError('Failed to list git worktrees in "$projectDir": $stderr');
  }

  final targetRef = 'refs/heads/$branch';
  String? currentPath;
  String? currentBranch;

  for (final line in (result.stdout as String).split('\u0000')) {
    if (line.isEmpty) {
      if (currentPath != null && currentBranch == targetRef) {
        return currentPath;
      }
      currentPath = null;
      currentBranch = null;
      continue;
    }
    if (line.startsWith('worktree ')) {
      currentPath = line.substring('worktree '.length);
      continue;
    }
    if (line.startsWith('branch ')) {
      currentBranch = line.substring('branch '.length);
    }
  }

  if (currentPath != null && currentBranch == targetRef) {
    return currentPath;
  }
  return null;
}

bool _isNothingToCommit(ProcessResult result) {
  final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
  return output.contains('nothing to commit') || output.contains('working tree clean');
}
