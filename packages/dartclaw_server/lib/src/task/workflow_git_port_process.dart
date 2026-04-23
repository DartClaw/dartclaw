import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock;
import 'package:dartclaw_security/dartclaw_security.dart' show SafeProcess;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show GitStatus, WorkflowGitCommit, WorkflowGitException, WorkflowGitMergeStrategy, WorkflowGitPort;
import 'package:path/path.dart' as p;

import 'git_credential_env.dart';
import 'remote_push_service.dart';
import 'worktree_manager.dart';

/// Production [WorkflowGitPort] backed by DartClaw's sanitized git process path.
final class WorkflowGitPortProcess implements WorkflowGitPort {
  final RepoLock _repoLock;

  // Retained as constructor dependencies so the composition layer can keep one
  // git boundary wired beside existing task git services.
  final WorktreeManager? worktreeManager;
  final RemotePushService? remotePushService;

  WorkflowGitPortProcess({RepoLock? repoLock, this.worktreeManager, this.remotePushService})
    : _repoLock = repoLock ?? RepoLock();

  @override
  Future<String> revParse(String worktreePath, String ref) async {
    final args = ref == '--abbrev-ref HEAD'
        ? <String>['rev-parse', '--abbrev-ref', 'HEAD']
        : <String>['rev-parse', ref];
    final result = await _expect(args, worktreePath, 'Failed to resolve ref $ref');
    return result.stdout.trim();
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
    return _lines(result.stdout);
  }

  @override
  Future<bool> pathExistsAtRef(String worktreePath, {required String ref, required String path}) async {
    final result = await _git(['cat-file', '-e', '$ref:$path'], workingDirectory: worktreePath);
    return result.exitCode == 0;
  }

  @override
  Future<GitStatus> status(String worktreePath) async {
    final result = await _expect(
      ['status', '--porcelain', '--untracked-files=all'],
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
  Future<List<String>> untrackedFiles(String worktreePath) async {
    return (await status(worktreePath)).untracked;
  }

  @override
  Future<List<String>> stashedPaths(String worktreePath, {int index = 0}) async {
    final result = await _git(['stash', 'show', '--name-only', 'stash@{$index}'], workingDirectory: worktreePath);
    if (result.exitCode != 0) {
      return const <String>[];
    }
    return _lines(result.stdout);
  }

  @override
  Future<void> add(String worktreePath, List<String> paths, {bool all = false}) async {
    if (!all && paths.isEmpty) return;
    final args = all ? <String>['add', '-A'] : <String>['add', '--', ...paths];
    await _expect(args, worktreePath, 'Failed to stage paths');
  }

  @override
  Future<WorkflowGitCommit> commit(
    String worktreePath, {
    required String message,
    String? authorName,
    String? authorEmail,
  }) async {
    return _withRepoLock(worktreePath, () async {
      final args = <String>[
        if (authorName != null && authorName.trim().isNotEmpty) ...['-c', 'user.name=$authorName'],
        if (authorEmail != null && authorEmail.trim().isNotEmpty) ...['-c', 'user.email=$authorEmail'],
        'commit',
        '-m',
        message,
      ];
      await _expect(args, worktreePath, 'Failed to commit staged changes');
      final sha = await revParse(worktreePath, 'HEAD');
      return WorkflowGitCommit(sha: sha, message: message);
    });
  }

  @override
  Future<void> checkout(String worktreePath, String ref) async {
    await _expect(['checkout', ref], worktreePath, 'Failed to checkout $ref');
  }

  @override
  Future<bool> stashPush(String worktreePath, {bool includeUntracked = true}) async {
    return _withRepoLock(worktreePath, () async {
      final args = <String>['stash', 'push', if (includeUntracked) '--include-untracked'];
      final result = await _expect(args, worktreePath, 'Failed to stash local changes');
      return !result.stdout.contains('No local changes to save');
    });
  }

  @override
  Future<void> stashPop(String worktreePath) async {
    await _withRepoLock(worktreePath, () => _expect(['stash', 'pop'], worktreePath, 'Failed to restore stash'));
  }

  @override
  Future<void> stashDrop(String worktreePath, {int index = 0}) async {
    await _withRepoLock(
      worktreePath,
      () => _expect(['stash', 'drop', 'stash@{$index}'], worktreePath, 'Failed to drop stash entry'),
    );
  }

  @override
  Future<void> merge(
    String worktreePath, {
    required String ref,
    required WorkflowGitMergeStrategy strategy,
    String? message,
  }) async {
    await _withRepoLock(worktreePath, () async {
      final args = switch (strategy) {
        WorkflowGitMergeStrategy.squash => <String>['merge', '--squash', ref],
        WorkflowGitMergeStrategy.merge => <String>['merge', '--no-ff', ref, '-m', message ?? 'Merge $ref'],
      };
      await _expect(args, worktreePath, 'Failed to merge $ref');
    });
  }

  @override
  Future<void> mergeAbort(String worktreePath) async {
    await _withRepoLock(worktreePath, () => _expect(['merge', '--abort'], worktreePath, 'Failed to abort merge'));
  }

  @override
  Future<void> resetHard(String worktreePath, String ref) async {
    await _withRepoLock(worktreePath, () => _expect(['reset', '--hard', ref], worktreePath, 'Failed to reset to $ref'));
  }

  Future<T> _withRepoLock<T>(String worktreePath, Future<T> Function() action) async {
    final lockKey = await _gitCommonDir(worktreePath);
    return _repoLock.acquire(lockKey, action);
  }

  Future<String> _gitCommonDir(String worktreePath) async {
    final result = await _git(['rev-parse', '--git-common-dir'], workingDirectory: worktreePath);
    if (result.exitCode != 0) {
      return p.normalize(p.absolute(worktreePath));
    }
    final raw = result.stdout.trim();
    if (raw.isEmpty) return p.normalize(p.absolute(worktreePath));
    return p.normalize(p.isAbsolute(raw) ? raw : p.join(worktreePath, raw));
  }

  Future<_GitProcessResult> _expect(List<String> args, String worktreePath, String message) async {
    final result = await _git(args, workingDirectory: worktreePath);
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

  Future<_GitProcessResult> _git(List<String> args, {required String workingDirectory}) async {
    final result = await SafeProcess.git(
      args,
      plan: const GitCredentialPlan.none(),
      workingDirectory: workingDirectory,
      noSystemConfig: true,
    );
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

  const _GitProcessResult({required this.exitCode, required this.stdout, required this.stderr});
}
