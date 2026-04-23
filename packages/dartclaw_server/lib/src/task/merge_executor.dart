import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show GitStatus, WorkflowGitCommit, WorkflowGitException, WorkflowGitMergeStrategy, WorkflowGitPort;
import 'package:logging/logging.dart';

import 'worktree_manager.dart';
import 'workflow_git_port_process.dart';

enum MergeStrategy { squash, merge }

sealed class MergeResult {
  const MergeResult();
}

class MergeSuccess extends MergeResult {
  final String commitSha;
  final String commitMessage;

  const MergeSuccess({required this.commitSha, required this.commitMessage});
}

class MergeConflict extends MergeResult {
  final List<String> conflictingFiles;
  final String details;

  const MergeConflict({required this.conflictingFiles, required this.details});

  Map<String, dynamic> toJson() => {'conflictingFiles': conflictingFiles, 'details': details};
}

sealed class PreMergeInvariantReason {
  const PreMergeInvariantReason();
}

final class UncleanIndex extends PreMergeInvariantReason {
  final List<String> modified;

  const UncleanIndex({required this.modified});
}

final class UntrackedOverlap extends PreMergeInvariantReason {
  final List<String> paths;

  const UntrackedOverlap({required this.paths});
}

final class TargetShaMismatch extends PreMergeInvariantReason {
  final String expected;
  final String actual;

  const TargetShaMismatch({required this.expected, required this.actual});
}

/// Thrown when a pre-merge repository invariant is already broken.
class PreMergeInvariantException extends WorktreeException implements Exception {
  final PreMergeInvariantReason reason;
  final String detail;

  const PreMergeInvariantException({required this.reason, required this.detail, super.gitStderr, super.exitCode})
    : super(detail);
}

/// Handles merging a worktree branch onto the base branch.
///
/// Supports squash-merge (default) and merge-commit strategies.
/// Stashes uncommitted changes before merge and restores them after.
class MergeExecutor {
  static final _log = Logger('MergeExecutor');

  final String _projectDir;
  final MergeStrategy _defaultStrategy;
  final WorkflowGitPort _gitPort;

  MergeExecutor({
    required String projectDir,
    MergeStrategy defaultStrategy = MergeStrategy.squash,
    WorkflowGitPort? gitPort,
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
    processRunner,
  }) : _projectDir = projectDir,
       _defaultStrategy = defaultStrategy,
       _gitPort =
           gitPort ??
           (processRunner == null
               ? WorkflowGitPortProcess()
               : _ProcessRunnerWorkflowGitPort(processRunner: processRunner));

  /// Merges [branch] onto [baseRef] using the configured strategy.
  ///
  /// On conflict, aborts the merge and returns [MergeConflict].
  /// Always restores the original branch and stashed changes.
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    String? expectedBaseSha,
    MergeStrategy? strategy,
  }) async {
    final effectiveStrategy = strategy ?? _defaultStrategy;
    final commitMessage = 'task($taskId): $taskTitle';
    await _assertPreMergeInvariants(baseRef: baseRef, expectedBaseSha: expectedBaseSha);

    // 1. Record current HEAD and branch
    final originalHead = await _revParse('HEAD', failureMessage: 'Failed to record current HEAD');

    final originalBranch = await _revParse('--abbrev-ref HEAD', failureMessage: 'Failed to record current branch');
    final isDetached = originalBranch == 'HEAD';

    // 2. Stash uncommitted changes
    final didStash = await _wrapGit('Failed to stash local changes', () => _gitPort.stashPush(_projectDir));

    try {
      // 3. Checkout base ref
      await _wrapGit('Failed to checkout $baseRef', () => _gitPort.checkout(_projectDir, baseRef));

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
          await _gitPort.checkout(_projectDir, originalHead);
        } else {
          await _gitPort.checkout(_projectDir, originalBranch);
        }
      }
    } finally {
      // 6. Restore stash
      if (didStash) {
        try {
          await _gitPort.stashPop(_projectDir);
        } on WorkflowGitException catch (e) {
          final popStderr = e.stderr;
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
            try {
              await _gitPort.resetHard(_projectDir, 'HEAD');
            } on WorkflowGitException catch (resetError) {
              _log.warning('Failed to reset working tree after stash-pop overlap: ${resetError.stderr}');
            }
            try {
              await _gitPort.stashDrop(_projectDir);
            } on WorkflowGitException catch (dropError) {
              _log.warning('Failed to drop stash after overlap: ${dropError.stderr}');
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
    try {
      await _gitPort.merge(_projectDir, ref: branch, strategy: WorkflowGitMergeStrategy.squash);
    } on WorkflowGitException catch (e) {
      return _handleConflict(e, strategy: MergeStrategy.squash);
    }

    // Commit the squashed changes
    try {
      final commit = await _gitPort.commit(_projectDir, message: commitMessage);
      return MergeSuccess(commitSha: commit.sha, commitMessage: commitMessage);
    } on WorkflowGitException catch (e) {
      if (e.stdout.contains('nothing to commit')) {
        final sha = await _revParse('HEAD', failureMessage: 'Failed to record empty merge HEAD');
        return MergeSuccess(commitSha: sha, commitMessage: commitMessage);
      }
      throw _toWorktreeException('Failed to commit squash merge', e);
    }
  }

  Future<MergeResult> _mergeMerge(String branch, String commitMessage) async {
    try {
      await _gitPort.merge(_projectDir, ref: branch, strategy: WorkflowGitMergeStrategy.merge, message: commitMessage);
    } on WorkflowGitException catch (e) {
      return _handleConflict(e, strategy: MergeStrategy.merge);
    }

    final sha = await _revParse('HEAD', failureMessage: 'Failed to record merge HEAD');
    return MergeSuccess(commitSha: sha, commitMessage: commitMessage);
  }

  Future<MergeConflict> _handleConflict(WorkflowGitException mergeError, {required MergeStrategy strategy}) async {
    // Get conflicting files
    final conflictingFiles = await _gitPort.diffNameOnly(_projectDir, diffFilter: 'U');

    final details = mergeError.stderr.isNotEmpty ? mergeError.stderr : mergeError.stdout;

    await _restoreAfterConflict(strategy);

    return MergeConflict(conflictingFiles: conflictingFiles, details: details.trim());
  }

  /// Restores the repository to a usable state after a failed merge attempt.
  ///
  /// Squash merges reset to `HEAD`; merge-commit flows abort the in-progress
  /// merge. Both branches log and continue on cleanup failure so the original
  /// conflict result can still propagate to the caller.
  Future<void> _restoreAfterConflict(MergeStrategy strategy) async {
    if (strategy == MergeStrategy.squash) {
      try {
        await _gitPort.resetHard(_projectDir, 'HEAD');
      } on WorkflowGitException catch (e) {
        _log.warning('Failed to restore repo after squash conflict: ${e.stderr}');
      }
      return;
    }

    try {
      await _gitPort.mergeAbort(_projectDir);
    } on WorkflowGitException catch (e) {
      _log.warning('Failed to abort merge conflict cleanly: ${e.stderr}');
    }
  }

  Future<void> _assertPreMergeInvariants({required String baseRef, String? expectedBaseSha}) async {
    final status = await _wrapGit(
      'Failed to verify merge precondition: repository index state is unknown',
      () => _gitPort.status(_projectDir),
    );
    if (!status.indexClean) {
      throw PreMergeInvariantException(
        reason: UncleanIndex(modified: status.modified),
        detail: 'Merge requires a clean index before checkout/merge. Resolve or stash local changes first.',
        gitStderr: status.modified.join('\n'),
      );
    }

    if (status.untracked.isNotEmpty) {
      final stashPaths = await _wrapGit('Failed to inspect stash paths', () => _gitPort.stashedPaths(_projectDir));
      final overlap = status.untracked.toSet().intersection(stashPaths.toSet()).toList()..sort();
      if (overlap.isNotEmpty) {
        throw PreMergeInvariantException(
          reason: UntrackedOverlap(paths: overlap),
          detail: 'Merge would overwrite untracked files that are also present in the current stash.',
          gitStderr: overlap.join('\n'),
        );
      }
    }

    final expected = expectedBaseSha?.trim();
    if (expected != null && expected.isNotEmpty) {
      final actual = await _revParse(baseRef, failureMessage: 'Failed to verify target branch SHA');
      if (actual != expected) {
        throw PreMergeInvariantException(
          reason: TargetShaMismatch(expected: expected, actual: actual),
          detail: 'Merge target $baseRef moved before merge entry.',
          gitStderr: 'expected $expected, actual $actual',
        );
      }
    }
  }

  Future<String> _revParse(String ref, {required String failureMessage}) async {
    return _wrapGit(failureMessage, () => _gitPort.revParse(_projectDir, ref));
  }

  Future<T> _wrapGit<T>(String failureMessage, Future<T> Function() action) async {
    try {
      return await action();
    } on WorkflowGitException catch (e) {
      throw _toWorktreeException(failureMessage, e);
    }
  }

  static WorktreeException _toWorktreeException(String message, WorkflowGitException e) {
    final detail = e.stderr.isNotEmpty ? e.stderr : e.stdout;
    return WorktreeException(message, gitStderr: detail, exitCode: e.exitCode);
  }
}

final class _ProcessRunnerWorkflowGitPort implements WorkflowGitPort {
  final Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})
  processRunner;

  const _ProcessRunnerWorkflowGitPort({required this.processRunner});

  @override
  Future<String> revParse(String worktreePath, String ref) async {
    final args = ref == '--abbrev-ref HEAD'
        ? <String>['rev-parse', '--abbrev-ref', 'HEAD']
        : <String>['rev-parse', ref];
    final result = await _expect(args, worktreePath, 'Failed to resolve ref $ref');
    return _stdout(result).trim();
  }

  @override
  Future<List<String>> diffNameOnly(
    String worktreePath, {
    String? against,
    bool cached = false,
    String? diffFilter,
  }) async {
    final args = <String>['diff'];
    if (cached) {
      args.add('--cached');
    }
    args.add('--name-only');
    if (diffFilter != null && diffFilter.trim().isNotEmpty) {
      args.add('--diff-filter=$diffFilter');
    }
    if (against != null && against.trim().isNotEmpty) {
      args.add(against);
    }
    final result = await _expect(args, worktreePath, 'Failed to list changed paths');
    return _lines(_stdout(result));
  }

  @override
  Future<bool> pathExistsAtRef(String worktreePath, {required String ref, required String path}) async {
    final result = await _git(['cat-file', '-e', '$ref:$path'], worktreePath);
    return result.exitCode == 0;
  }

  @override
  Future<GitStatus> status(String worktreePath) async {
    final result = await _expect(['status', '--porcelain'], worktreePath, 'Failed to inspect status');
    final modified = <String>[];
    final untracked = <String>[];
    for (final line in _lines(_stdout(result))) {
      if (line.startsWith('?? ')) {
        untracked.add(line.substring(3).trim());
      } else if (line.length > 3) {
        modified.add(line.substring(3).trim());
      } else {
        modified.add(line.trim());
      }
    }
    return GitStatus(indexClean: modified.isEmpty, modified: modified, untracked: untracked);
  }

  @override
  Future<List<String>> untrackedFiles(String worktreePath) async {
    return (await status(worktreePath)).untracked;
  }

  @override
  Future<List<String>> stashedPaths(String worktreePath, {int index = 0}) async {
    final result = await _git(['stash', 'show', '--name-only', 'stash@{$index}'], worktreePath);
    if (result.exitCode != 0) return const <String>[];
    return _lines(_stdout(result));
  }

  @override
  Future<void> add(String worktreePath, List<String> paths, {bool all = false}) async {
    if (!all && paths.isEmpty) return;
    await _expect(all ? <String>['add', '-A'] : <String>['add', '--', ...paths], worktreePath, 'Failed to stage paths');
  }

  @override
  Future<WorkflowGitCommit> commit(
    String worktreePath, {
    required String message,
    String? authorName,
    String? authorEmail,
  }) async {
    final args = <String>[
      if (authorName != null && authorName.trim().isNotEmpty) ...['-c', 'user.name=$authorName'],
      if (authorEmail != null && authorEmail.trim().isNotEmpty) ...['-c', 'user.email=$authorEmail'],
      'commit',
      '-m',
      message,
    ];
    await _expect(args, worktreePath, 'Failed to commit staged changes');
    return WorkflowGitCommit(sha: await revParse(worktreePath, 'HEAD'), message: message);
  }

  @override
  Future<void> checkout(String worktreePath, String ref) async {
    await _expect(['checkout', ref], worktreePath, 'Failed to checkout $ref');
  }

  @override
  Future<bool> stashPush(String worktreePath, {bool includeUntracked = true}) async {
    final args = <String>['stash', if (includeUntracked) '--include-untracked'];
    final result = await _expect(args, worktreePath, 'Failed to stash local changes');
    return !_stdout(result).contains('No local changes to save');
  }

  @override
  Future<void> stashPop(String worktreePath) async {
    await _expect(['stash', 'pop'], worktreePath, 'Failed to restore stash');
  }

  @override
  Future<void> stashDrop(String worktreePath, {int index = 0}) async {
    await _expect(['stash', 'drop'], worktreePath, 'Failed to drop stash entry');
  }

  @override
  Future<void> merge(
    String worktreePath, {
    required String ref,
    required WorkflowGitMergeStrategy strategy,
    String? message,
  }) async {
    final args = switch (strategy) {
      WorkflowGitMergeStrategy.squash => <String>['merge', '--squash', ref],
      WorkflowGitMergeStrategy.merge => <String>['merge', '--no-ff', ref, '-m', message ?? 'Merge $ref'],
    };
    await _expect(args, worktreePath, 'Failed to merge $ref');
  }

  @override
  Future<void> mergeAbort(String worktreePath) async {
    await _expect(['merge', '--abort'], worktreePath, 'Failed to abort merge');
  }

  @override
  Future<void> resetHard(String worktreePath, String ref) async {
    await _expect(['reset', '--hard', ref], worktreePath, 'Failed to reset');
  }

  Future<ProcessResult> _expect(List<String> args, String worktreePath, String message) async {
    final result = await _git(args, worktreePath);
    if (result.exitCode == 0) return result;
    throw WorkflowGitException(
      message,
      args: args,
      stdout: _stdout(result),
      stderr: _stderr(result),
      exitCode: result.exitCode,
    );
  }

  Future<ProcessResult> _git(List<String> args, String worktreePath) {
    return processRunner('git', args, workingDirectory: worktreePath);
  }

  static List<String> _lines(String output) =>
      output.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();

  static String _stdout(ProcessResult result) => result.stdout as String;

  static String _stderr(ProcessResult result) => result.stderr as String;
}
