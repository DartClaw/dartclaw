import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show GitRunner, runGit;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show GitStatus, WorkflowGitCommit, WorkflowGitException, WorkflowGitMergeStrategy, WorkflowGitPort;
import 'package:path/path.dart' as p;

import 'host_worktree_git.dart';
import 'remote_push_service.dart';
import 'worktree_manager.dart';

/// Production [WorkflowGitPort] backed by DartClaw's sanitized git process path.
///
/// Every operation runs through [runHostWorktreeGit], so a worktree other than
/// its project dir runs with the Git location the project recorded and a
/// tampered one throws [TamperedWorktreeException].
final class WorkflowGitPortProcess implements WorkflowGitPort {
  final RepoLock _repoLock;
  final GitRunner _runGit;

  // Retained as constructor dependencies so the composition layer can keep one
  // git boundary wired beside existing task git services.
  final WorktreeManager? worktreeManager;
  final RemotePushService? remotePushService;

  new({RepoLock? repoLock, this.worktreeManager, this.remotePushService, GitRunner? processRunner})
    : _repoLock = repoLock ?? RepoLock(),
      _runGit = processRunner ?? runGit;

  @override
  Future<String> revParse(String worktreePath, String ref, {required String projectDir}) async {
    final result = await _expect(['rev-parse', ref], projectDir, worktreePath, 'Failed to resolve ref $ref');
    return result.stdout.trim();
  }

  @override
  Future<String> currentBranch(String worktreePath, {required String projectDir}) async {
    final result = await _git(['symbolic-ref', '--quiet', '--short', 'HEAD'], projectDir, worktreePath);
    if (result.exitCode == 0) {
      final branch = result.stdout.trim();
      if (branch.isNotEmpty) return branch;
    }
    return 'HEAD';
  }

  @override
  Future<List<String>> diffNameOnly(
    String worktreePath, {
    required String projectDir,
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
    final result = await _expect(args, projectDir, worktreePath, 'Failed to list changed paths');
    final paths = _lines(result.stdout).toSet();
    if (!cached && (diffFilter == null || diffFilter.trim().isEmpty)) {
      paths.addAll(await untrackedFiles(worktreePath, projectDir: projectDir));
    }
    return paths.toList()..sort();
  }

  @override
  Future<bool> pathExistsAtRef(
    String worktreePath, {
    required String projectDir,
    required String ref,
    required String path,
  }) async {
    final result = await _git(['cat-file', '-e', '$ref:$path'], projectDir, worktreePath);
    return result.exitCode == 0;
  }

  @override
  Future<GitStatus> status(String worktreePath, {required String projectDir}) async {
    final result = await _expect(
      ['status', '--porcelain', '--untracked-files=all'],
      projectDir,
      worktreePath,
      'Failed to inspect working tree status',
    );
    final modified = <String>[];
    final untracked = <String>[];
    for (final line in _lines(result.stdout)) {
      if (line.startsWith('?? ')) {
        untracked.add(line.substring(3).trim());
      } else if (line.length > 3) {
        modified.add(line.substring(3).trim());
      } else {
        modified.add(line.trim());
      }
    }
    return GitStatus(
      indexClean: modified.isEmpty,
      modified: List.unmodifiable(modified),
      untracked: List.unmodifiable(untracked),
    );
  }

  @override
  Future<List<String>> untrackedFiles(String worktreePath, {required String projectDir}) async {
    return (await status(worktreePath, projectDir: projectDir)).untracked;
  }

  @override
  Future<List<String>> stashedPaths(String worktreePath, {required String projectDir, int index = 0}) async {
    final result = await _git(['stash', 'show', '--name-only', 'stash@{$index}'], projectDir, worktreePath);
    if (result.exitCode != 0) {
      return const <String>[];
    }
    return _lines(result.stdout);
  }

  @override
  Future<void> add(String worktreePath, List<String> paths, {required String projectDir, bool all = false}) async {
    if (!all && paths.isEmpty) return;
    final args = all ? <String>['add', '-A'] : <String>['add', '--', ...paths];
    await _expect(args, projectDir, worktreePath, 'Failed to stage paths');
  }

  @override
  Future<WorkflowGitCommit> commit(
    String worktreePath, {
    required String projectDir,
    required String message,
    String? authorName,
    String? authorEmail,
  }) async {
    return _withRepoLock(projectDir, () async {
      final args = <String>[
        if (authorName != null && authorName.trim().isNotEmpty) ...['-c', 'user.name=$authorName'],
        if (authorEmail != null && authorEmail.trim().isNotEmpty) ...['-c', 'user.email=$authorEmail'],
        'commit',
        '-m',
        message,
      ];
      await _expect(args, projectDir, worktreePath, 'Failed to commit staged changes');
      final sha = await revParse(worktreePath, 'HEAD', projectDir: projectDir);
      return WorkflowGitCommit(sha: sha, message: message);
    });
  }

  @override
  Future<void> checkout(String worktreePath, String ref, {required String projectDir}) async {
    await _expect(['checkout', ref], projectDir, worktreePath, 'Failed to checkout $ref');
  }

  @override
  Future<bool> stashPush(String worktreePath, {required String projectDir, bool includeUntracked = true}) async {
    return _withRepoLock(projectDir, () async {
      final args = <String>['stash', 'push', if (includeUntracked) '--include-untracked'];
      final result = await _expect(args, projectDir, worktreePath, 'Failed to stash local changes');
      return !result.stdout.contains('No local changes to save');
    });
  }

  @override
  Future<void> stashPop(String worktreePath, {required String projectDir}) async {
    await _withRepoLock(
      projectDir,
      () => _expect(['stash', 'pop'], projectDir, worktreePath, 'Failed to restore stash'),
    );
  }

  @override
  Future<void> stashDrop(String worktreePath, {required String projectDir, int index = 0}) async {
    await _withRepoLock(
      projectDir,
      () => _expect(['stash', 'drop', 'stash@{$index}'], projectDir, worktreePath, 'Failed to drop stash entry'),
    );
  }

  @override
  Future<void> merge(
    String worktreePath, {
    required String projectDir,
    required String ref,
    required WorkflowGitMergeStrategy strategy,
    String? message,
  }) async {
    await _withRepoLock(projectDir, () async {
      final args = switch (strategy) {
        WorkflowGitMergeStrategy.squash => <String>['merge', '--squash', ref],
        WorkflowGitMergeStrategy.merge => <String>['merge', '--no-ff', ref, '-m', message ?? 'Merge $ref'],
      };
      await _expect(args, projectDir, worktreePath, 'Failed to merge $ref');
    });
  }

  @override
  Future<void> mergeAbort(String worktreePath, {required String projectDir}) async {
    await _withRepoLock(
      projectDir,
      () => _expect(['merge', '--abort'], projectDir, worktreePath, 'Failed to abort merge'),
    );
  }

  @override
  Future<void> resetHard(String worktreePath, String ref, {required String projectDir}) async {
    await _withRepoLock(
      projectDir,
      () => _expect(['reset', '--hard', ref], projectDir, worktreePath, 'Failed to reset to $ref'),
    );
  }

  /// Serializes on the project's common dir, resolved in [projectDir] so a
  /// worktree's gitlink cannot choose the lock it shares.
  Future<T> _withRepoLock<T>(String projectDir, Future<T> Function() action) async {
    final String lockKey;
    try {
      lockKey = await resolveHostGitCommonDir(projectDir, runner: _runGit);
    } on WorktreeException {
      return _repoLock.acquire(p.normalize(p.absolute(projectDir)), action);
    }
    return _repoLock.acquire(lockKey, action);
  }

  Future<_GitProcessResult> _expect(List<String> args, String projectDir, String worktreePath, String message) async {
    final result = await _git(args, projectDir, worktreePath);
    if (result.exitCode == 0) {
      return result;
    }
    throw WorkflowGitException(
      message,
      args: args,
      stdout: result.stdout,
      stderr: result.stderr,
      exitCode: result.exitCode,
    );
  }

  Future<_GitProcessResult> _git(List<String> args, String projectDir, String worktreePath) async {
    final result = await runHostWorktreeGit(args, projectDir: projectDir, worktreePath: worktreePath, runner: _runGit);
    return _GitProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  }

  static List<String> _lines(String output) =>
      output.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
}

final class _GitProcessResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const new({required this.exitCode, required this.stdout, required this.stderr});
}
