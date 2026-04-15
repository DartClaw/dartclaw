import 'dart:io';

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

  final status = await Process.run('git', [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ], workingDirectory: worktreePath);
  if (status.exitCode != 0) {
    final stderr = (status.stderr as String).trim();
    throw StateError('Failed to inspect workflow worktree "$worktreePath": $stderr');
  }
  if ((status.stdout as String).trim().isEmpty) {
    return;
  }

  final add = await Process.run('git', ['add', '-A'], workingDirectory: worktreePath);
  if (add.exitCode != 0) {
    final stderr = (add.stderr as String).trim();
    throw StateError('Failed to stage workflow worktree changes in "$worktreePath": $stderr');
  }

  final commit = await Process.run('git', ['commit', '-m', commitMessage], workingDirectory: worktreePath);
  if (commit.exitCode != 0 && !_isNothingToCommit(commit)) {
    final stderr = (commit.stderr as String).trim();
    final stdout = (commit.stdout as String).trim();
    final detail = stderr.isNotEmpty ? stderr : stdout;
    throw StateError('Failed to commit workflow worktree changes in "$worktreePath": $detail');
  }
}

Future<String?> _findWorktreePathForBranch({required String projectDir, required String branch}) async {
  final result = await Process.run('git', ['worktree', 'list', '--porcelain'], workingDirectory: projectDir);
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
