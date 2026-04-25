import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_server/dartclaw_server.dart'
    show GitCredentialPlan, MergeConflict, MergeExecutor, MergeStrategy, MergeSuccess;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionError,
        WorkflowGitPromotionResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult;
import 'package:path/path.dart' as p;

final _workflowGitRepoLock = RepoLock();

Future<ProcessResult> _workflowGit(List<String> args, {required String workingDirectory}) {
  return SafeProcess.git(
    args,
    plan: const GitCredentialPlan.none(),
    workingDirectory: workingDirectory,
    noSystemConfig: true,
  );
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
}) async {
  final worktreePath = await _findWorktreePathForBranch(projectDir: projectDir, branch: branch);
  if (worktreePath == null) {
    return;
  }

  final status = await _workflowGit(['status', '--porcelain', '--untracked-files=all'], workingDirectory: worktreePath);
  if (status.exitCode != 0) {
    final stderr = (status.stderr as String).trim();
    throw StateError('Failed to inspect workflow worktree "$worktreePath": $stderr');
  }
  if ((status.stdout as String).trim().isEmpty) {
    return;
  }

  final add = await _workflowGit(['add', '-A'], workingDirectory: worktreePath);
  if (add.exitCode != 0) {
    final stderr = (add.stderr as String).trim();
    throw StateError('Failed to stage workflow worktree changes in "$worktreePath": $stderr');
  }

  final commit = await _workflowGit(['commit', '-m', commitMessage], workingDirectory: worktreePath);
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
    return _cleanupWorktreeForRetryUnlocked(
      projectDir: projectDir,
      branch: branch,
      preAttemptSha: preAttemptSha,
    );
  });
}

Future<String?> _cleanupWorktreeForRetryUnlocked({
  required String projectDir,
  required String branch,
  required String preAttemptSha,
}) async {
  final worktreePath = await _findWorktreePathForBranch(projectDir: projectDir, branch: branch) ?? projectDir;

  // Best-effort: abort any in-progress merge; ignore failure.
  final abortResult = await _workflowGit(['merge', '--abort'], workingDirectory: worktreePath);
  if (abortResult.exitCode != 0) {
    final detail = (abortResult.stderr as String).trim();
    if (detail.isNotEmpty && !detail.contains('There is no merge to abort') && !detail.contains('MERGE_HEAD')) {
      // Non-trivial abort failure; log but continue.
      stderr.writeln('[workflow-git] cleanup: merge --abort ignored: $detail');
    }
  }

  final resetResult = await _workflowGit(
    ['reset', '--hard', preAttemptSha],
    workingDirectory: worktreePath,
  );
  if (resetResult.exitCode != 0) {
    final detail = (resetResult.stderr as String).trim();
    return 'cleanup failed: git reset --hard exit=${resetResult.exitCode} path=$worktreePath'
        '${detail.isEmpty ? '' : ': $detail'}';
  }

  final cleanResult = await _workflowGit(['clean', '-fd'], workingDirectory: worktreePath);
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
    final worktreePath = await _findWorktreePathForBranch(projectDir: projectDir, branch: branch) ?? projectDir;
    final result = await _workflowGit(['rev-parse', branch], workingDirectory: worktreePath);
    if (result.exitCode != 0) return null;
    final sha = (result.stdout as String).trim();
    return sha.isNotEmpty ? sha : null;
  });
}

Future<WorkflowGitPromotionResult> promoteWorkflowBranchLocally({
  required String projectDir,
  required String runId,
  required String branch,
  required String integrationBranch,
  required String strategy,
  String? storyId,
}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    return _promoteWorkflowBranchLocallyUnlocked(
      projectDir: projectDir,
      runId: runId,
      branch: branch,
      integrationBranch: integrationBranch,
      strategy: strategy,
      storyId: storyId,
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
}) async {
  try {
    await commitWorkflowWorktreeChangesIfNeeded(
      projectDir: projectDir,
      branch: branch,
      commitMessage: 'workflow(${storyId ?? runId}): prepare promotion',
    );
    // Sweep pending changes in the integration worktree too. In inline mode
    // the integration branch is checked out in the project root while
    // upstream artifact-producing steps (andthen-prd / andthen-plan) run
    // there; anything they wrote that the artifact committer did not add
    // (intermediate files, STATE/LEARNINGS edits, untracked research docs)
    // would leave a dirty index/tree and fail MergeExecutor's pre-merge
    // invariant check with "Merge requires a clean index". Committing the
    // leftover state now folds it into the integration history instead of
    // silently aborting promotion.
    await commitWorkflowWorktreeChangesIfNeeded(
      projectDir: projectDir,
      branch: integrationBranch,
      commitMessage: 'workflow($runId): sweep integration worktree before promotion',
    );
  } catch (error) {
    return WorkflowGitPromotionError(error.toString());
  }

  try {
    final mergeResult = await _withIntegrationWorktree(
      projectDir: projectDir,
      branch: integrationBranch,
      action: (integrationWorktreeDir) async {
        final expectedBaseShaResult = await _workflowGit([
          'rev-parse',
          integrationBranch,
        ], workingDirectory: integrationWorktreeDir);
        if (expectedBaseShaResult.exitCode != 0) {
          throw StateError('Failed to record merge target "$integrationBranch": ${expectedBaseShaResult.stderr}');
        }
        final mergeExecutor = MergeExecutor(
          projectDir: integrationWorktreeDir,
          defaultStrategy: strategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
        );
        return mergeExecutor.merge(
          branch: branch,
          baseRef: integrationBranch,
          taskId: storyId ?? runId,
          taskTitle: storyId == null ? 'workflow promotion' : 'promote $storyId',
          expectedBaseSha: (expectedBaseShaResult.stdout as String).trim(),
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
  final existingWorktree = await _findWorktreePathForBranch(projectDir: projectDir, branch: branch);
  if (existingWorktree != null) {
    return action(existingWorktree);
  }

  final tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_integration_');
  final worktreePath = p.join(tempDir.path, 'worktree');
  final add = await _workflowGit(['worktree', 'add', worktreePath, branch], workingDirectory: projectDir);
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
    await _workflowGit(['worktree', 'remove', '--force', worktreePath], workingDirectory: projectDir);
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
  String remote = 'origin',
}) {
  return _workflowGitRepoLock.acquire(_repoLockKey(projectDir), () async {
    return _publishWorkflowBranchLocallyUnlocked(projectDir: projectDir, branch: branch, remote: remote);
  });
}

Future<WorkflowGitPublishResult> _publishWorkflowBranchLocallyUnlocked({
  required String projectDir,
  required String branch,
  required String remote,
}) async {
  // Commit any pending worktree changes before pushing. For shared-worktree
  // workflows the agent may leave uncommitted changes in the worktree that is
  // checked out on [branch]. Without this step the push would succeed but the
  // remote branch would have no new commits relative to the base.
  try {
    await commitWorkflowWorktreeChangesIfNeeded(
      projectDir: projectDir,
      branch: branch,
      commitMessage: 'workflow: prepare publish',
    );
  } catch (e) {
    return WorkflowGitPublishResult(
      status: 'failed',
      branch: branch,
      remote: remote,
      prUrl: '',
      error: 'Failed to commit pending worktree changes before publish: $e',
    );
  }

  final push = await _workflowGit(['push', remote, branch], workingDirectory: projectDir);
  if (push.exitCode != 0) {
    return WorkflowGitPublishResult(
      status: 'failed',
      branch: branch,
      remote: remote,
      prUrl: '',
      error: (push.stderr as String).trim(),
    );
  }

  final remoteRef = 'refs/heads/$branch:refs/remotes/$remote/$branch';
  final fetch = await _workflowGit(['fetch', '--no-tags', remote, remoteRef], workingDirectory: projectDir);
  if (fetch.exitCode != 0) {
    final stderr = (fetch.stderr as String).trim();
    final stdout = (fetch.stdout as String).trim();
    final detail = stderr.isNotEmpty ? stderr : stdout;
    return WorkflowGitPublishResult(
      status: 'failed',
      branch: branch,
      remote: remote,
      prUrl: '',
      error: 'Failed to refresh remote-tracking ref for "$branch": $detail',
    );
  }

  final verify = await _workflowGit([
    'rev-parse',
    '--verify',
    'refs/remotes/$remote/$branch',
  ], workingDirectory: projectDir);
  if (verify.exitCode != 0) {
    return WorkflowGitPublishResult(
      status: 'failed',
      branch: branch,
      remote: remote,
      prUrl: '',
      error: 'Push reported success but refs/remotes/$remote/$branch is unavailable locally',
    );
  }

  return WorkflowGitPublishResult(status: 'success', branch: branch, remote: remote, prUrl: '');
}

Future<String?> _findWorktreePathForBranch({required String projectDir, required String branch}) async {
  final result = await _workflowGit(['worktree', 'list', '--porcelain'], workingDirectory: projectDir);
  if (result.exitCode != 0) {
    final stderr = (result.stderr as String).trim();
    throw StateError('Failed to list git worktrees in "$projectDir": $stderr');
  }

  final targetRef = 'refs/heads/$branch';
  String? currentPath;
  String? currentBranch;

  for (final rawLine in (result.stdout as String).split('\n')) {
    final line = rawLine.trimRight();
    if (line.isEmpty) {
      if (currentPath != null && currentBranch == targetRef) {
        return currentPath;
      }
      currentPath = null;
      currentBranch = null;
      continue;
    }
    if (line.startsWith('worktree ')) {
      currentPath = line.substring('worktree '.length).trim();
      continue;
    }
    if (line.startsWith('branch ')) {
      currentBranch = line.substring('branch '.length).trim();
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
