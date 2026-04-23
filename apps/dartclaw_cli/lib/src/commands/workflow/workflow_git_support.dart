import 'dart:io';

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

Future<ProcessResult> _workflowGit(List<String> args, {required String workingDirectory}) {
  return SafeProcess.git(
    args,
    plan: const GitCredentialPlan.none(),
    workingDirectory: workingDirectory,
    noSystemConfig: true,
  );
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

Future<WorkflowGitPromotionResult> promoteWorkflowBranchLocally({
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
  } catch (error) {
    return WorkflowGitPromotionError(error.toString());
  }

  final integrationWorktreeDir =
      await _findWorktreePathForBranch(projectDir: projectDir, branch: integrationBranch) ?? projectDir;
  final expectedBaseShaResult = await _workflowGit([
    'rev-parse',
    integrationBranch,
  ], workingDirectory: integrationWorktreeDir);
  if (expectedBaseShaResult.exitCode != 0) {
    return WorkflowGitPromotionError(
      'Failed to record merge target "$integrationBranch": ${expectedBaseShaResult.stderr}',
    );
  }
  final mergeExecutor = MergeExecutor(
    projectDir: integrationWorktreeDir,
    defaultStrategy: strategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
  );
  final mergeResult = await mergeExecutor.merge(
    branch: branch,
    baseRef: integrationBranch,
    taskId: storyId ?? runId,
    taskTitle: storyId == null ? 'workflow promotion' : 'promote $storyId',
    expectedBaseSha: (expectedBaseShaResult.stdout as String).trim(),
    strategy: strategy == 'merge' ? MergeStrategy.merge : MergeStrategy.squash,
  );

  return switch (mergeResult) {
    MergeSuccess(:final commitSha) => WorkflowGitPromotionSuccess(commitSha: commitSha),
    MergeConflict(:final conflictingFiles, :final details) => WorkflowGitPromotionConflict(
      conflictingFiles: conflictingFiles,
      details: details,
    ),
  };
}

Future<WorkflowGitPublishResult> publishWorkflowBranchLocally({
  required String projectDir,
  required String branch,
  String remote = 'origin',
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
