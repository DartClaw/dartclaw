import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';

import 'git_credential_env.dart';
import 'worktree_manager.dart';

/// Strategy for merging a worktree branch onto the base branch.
enum MergeStrategy { squash, merge }

/// Result of a merge attempt.
sealed class MergeResult {
  const MergeResult();
}

/// Successful merge with the resulting commit SHA.
class MergeSuccess extends MergeResult {
  final String commitSha;
  final String commitMessage;

  const MergeSuccess({required this.commitSha, required this.commitMessage});
}

/// Merge failed due to conflicts.
class MergeConflict extends MergeResult {
  final List<String> conflictingFiles;
  final String details;

  const MergeConflict({required this.conflictingFiles, required this.details});

  Map<String, dynamic> toJson() => {'conflictingFiles': conflictingFiles, 'details': details};
}

/// Handles merging a worktree branch onto the base branch.
///
/// Supports squash-merge (default) and merge-commit strategies.
/// Stashes uncommitted changes before merge and restores them after.
class MergeExecutor {
  static final _log = Logger('MergeExecutor');

  final String _projectDir;
  final MergeStrategy _defaultStrategy;
  final Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})
  _runProcess;

  MergeExecutor({
    required String projectDir,
    MergeStrategy defaultStrategy = MergeStrategy.squash,
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
    processRunner,
  }) : _projectDir = projectDir,
       _defaultStrategy = defaultStrategy,
       _runProcess = processRunner ?? _defaultProcessRunner;

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    if (executable == 'git') {
      return SafeProcess.git(arguments, plan: const GitCredentialPlan.none(), workingDirectory: workingDirectory);
    }
    return Process.run(executable, arguments, workingDirectory: workingDirectory);
  }

  /// Merges [branch] onto [baseRef] using the configured strategy.
  ///
  /// On conflict, aborts the merge and returns [MergeConflict].
  /// Always restores the original branch and stashed changes.
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    MergeStrategy? strategy,
  }) async {
    final effectiveStrategy = strategy ?? _defaultStrategy;
    final commitMessage = 'task($taskId): $taskTitle';

    // 1. Record current HEAD and branch
    final originalHeadResult = await _git(['rev-parse', 'HEAD']);
    if (originalHeadResult.exitCode != 0) {
      throw WorktreeException(
        'Failed to record current HEAD',
        gitStderr: _stderr(originalHeadResult),
        exitCode: originalHeadResult.exitCode,
      );
    }
    final originalHead = _stdout(originalHeadResult).trim();

    final originalBranchResult = await _git(['rev-parse', '--abbrev-ref', 'HEAD']);
    final originalBranch = _stdout(originalBranchResult).trim();
    final isDetached = originalBranch == 'HEAD';

    // 2. Stash uncommitted changes
    final stashResult = await _git(['stash', '--include-untracked']);
    final didStash = stashResult.exitCode == 0 && !_stdout(stashResult).contains('No local changes to save');

    try {
      // 3. Checkout base ref
      final checkoutResult = await _git(['checkout', baseRef]);
      if (checkoutResult.exitCode != 0) {
        throw WorktreeException(
          'Failed to checkout $baseRef',
          gitStderr: _stderr(checkoutResult),
          exitCode: checkoutResult.exitCode,
        );
      }

      try {
        // 4. Merge
        MergeResult result;
        if (effectiveStrategy == MergeStrategy.squash) {
          result = await _squashMerge(branch, commitMessage);
        } else {
          result = await _mergeMerge(branch, commitMessage);
        }

        if (result is MergeSuccess) {
          _log.info(
            'Merged branch $branch onto $baseRef '
            '(strategy: ${effectiveStrategy.name}, sha: ${result.commitSha})',
          );
        } else if (result is MergeConflict) {
          _log.warning(
            'Merge conflict on branch $branch: '
            '${result.conflictingFiles.length} conflicting file(s)',
          );
        }

        return result;
      } finally {
        // 5. Restore original branch/HEAD
        if (isDetached) {
          await _git(['checkout', originalHead]);
        } else {
          await _git(['checkout', originalBranch]);
        }
      }
    } finally {
      // 6. Restore stash
      if (didStash) {
        final popResult = await _git(['stash', 'pop']);
        if (popResult.exitCode != 0) {
          final popStderr = _stderr(popResult);
          if (_isUntrackedOverlap(popStderr)) {
            // The stash contained untracked files that the completed merge
            // already materialised in the working tree (common in map/fan-in
            // flows where each item adds the same generated file). `git stash
            // pop` leaves the stash entry in place on failure, so drop it
            // explicitly to avoid stash-list pollution across sequential merges.
            _log.info(
              'Stashed untracked files overlap with merge result for branch $branch; '
              'dropping stash entry. Overlap: ${popStderr.trim()}',
            );
            // The partial stash pop on the overlap path can leave the index
            // with unmerged entries (`git stash pop` aborts mid-apply when
            // the untracked file collision fires). A subsequent `git checkout`
            // then fails with "you need to resolve your current index first",
            // which cascades into a workflow failure even though the merge
            // itself succeeded. Reset to HEAD to scrub any partial apply
            // before dropping the stash — safe because the stash contents
            // are intentionally being discarded.
            final resetResult = await _git(['reset', '--hard', 'HEAD']);
            if (resetResult.exitCode != 0) {
              _log.warning(
                'Failed to reset working tree after stash-pop overlap: ${_stderr(resetResult)}',
              );
            }
            final dropResult = await _git(['stash', 'drop']);
            if (dropResult.exitCode != 0) {
              _log.warning('Failed to drop stash after overlap: ${_stderr(dropResult)}');
            }
          } else {
            _log.warning('Failed to restore stash: $popStderr');
          }
        }
      }
    }
  }

  /// Detects git's "already exists, no checkout" stash-pop failure mode, which
  /// means the stashed untracked files collided with files now present in the
  /// working tree (typically because the just-completed merge introduced them).
  static bool _isUntrackedOverlap(String stderr) {
    return stderr.contains('already exists, no checkout');
  }

  Future<MergeResult> _squashMerge(String branch, String commitMessage) async {
    final mergeResult = await _git(['merge', '--squash', branch]);

    if (mergeResult.exitCode != 0) {
      return _handleConflict(mergeResult, strategy: MergeStrategy.squash);
    }

    // Commit the squashed changes
    final commitResult = await _git(['commit', '-m', commitMessage]);
    if (commitResult.exitCode != 0) {
      // If commit fails with "nothing to commit", treat as empty merge success
      if (_stdout(commitResult).contains('nothing to commit')) {
        final shaResult = await _git(['rev-parse', 'HEAD']);
        return MergeSuccess(commitSha: _stdout(shaResult).trim(), commitMessage: commitMessage);
      }
      throw WorktreeException(
        'Failed to commit squash merge',
        gitStderr: _stderr(commitResult),
        exitCode: commitResult.exitCode,
      );
    }

    final shaResult = await _git(['rev-parse', 'HEAD']);
    return MergeSuccess(commitSha: _stdout(shaResult).trim(), commitMessage: commitMessage);
  }

  Future<MergeResult> _mergeMerge(String branch, String commitMessage) async {
    final mergeResult = await _git(['merge', '--no-ff', branch, '-m', commitMessage]);

    if (mergeResult.exitCode != 0) {
      return _handleConflict(mergeResult, strategy: MergeStrategy.merge);
    }

    final shaResult = await _git(['rev-parse', 'HEAD']);
    return MergeSuccess(commitSha: _stdout(shaResult).trim(), commitMessage: commitMessage);
  }

  Future<MergeConflict> _handleConflict(ProcessResult mergeResult, {required MergeStrategy strategy}) async {
    // Get conflicting files
    final conflictResult = await _git(['diff', '--name-only', '--diff-filter=U']);
    final conflictingFiles = _stdout(conflictResult).trim().split('\n').where((line) => line.isNotEmpty).toList();

    final details = _stderr(mergeResult).isNotEmpty ? _stderr(mergeResult) : _stdout(mergeResult);

    await _restoreAfterConflict(strategy);

    return MergeConflict(conflictingFiles: conflictingFiles, details: details.trim());
  }

  Future<void> _restoreAfterConflict(MergeStrategy strategy) async {
    if (strategy == MergeStrategy.squash) {
      final resetResult = await _git(['reset', '--hard', 'HEAD']);
      if (resetResult.exitCode != 0) {
        _log.warning('Failed to restore repo after squash conflict: ${_stderr(resetResult)}');
      }
      return;
    }

    final abortResult = await _git(['merge', '--abort']);
    if (abortResult.exitCode != 0) {
      _log.warning('Failed to abort merge conflict cleanly: ${_stderr(abortResult)}');
    }
  }

  Future<ProcessResult> _git(List<String> args) {
    return _runProcess('git', args, workingDirectory: _projectDir);
  }

  static String _stdout(ProcessResult result) => result.stdout as String;
  static String _stderr(ProcessResult result) => result.stderr as String;
}
