/// Mockable git boundary for workflow execution.
///
/// All git operations from `dartclaw_workflow/lib` route through this port so
/// tests can use an in-memory implementation and production can centralize
/// subprocess policy.
///
/// Codex CLI stderr capture and transient-vs-semantic subprocess-exit classification (fix 15) are out of scope. Follow-up owned by `workflow-observability-and-correctness-remediation-plan.md` S04.
abstract interface class WorkflowGitPort {
  /// Resolves [ref] to a commit SHA or symbolic ref name.
  Future<String> revParse(String worktreePath, String ref);

  /// Returns paths reported by `git diff --name-only`.
  Future<List<String>> diffNameOnly(String worktreePath, {String? against, bool cached = false, String? diffFilter});

  /// Returns whether [path] exists at [ref].
  Future<bool> pathExistsAtRef(String worktreePath, {required String ref, required String path});

  /// Returns the current working-tree status.
  Future<GitStatus> status(String worktreePath);

  /// Returns untracked working-tree paths.
  Future<List<String>> untrackedFiles(String worktreePath);

  /// Returns paths contained in a stash entry.
  Future<List<String>> stashedPaths(String worktreePath, {int index = 0});

  /// Stages [paths].
  Future<void> add(String worktreePath, List<String> paths, {bool all = false});

  /// Commits staged changes.
  Future<WorkflowGitCommit> commit(
    String worktreePath, {
    required String message,
    String? authorName,
    String? authorEmail,
  });

  /// Checks out [ref].
  Future<void> checkout(String worktreePath, String ref);

  /// Stashes local changes and returns whether a stash entry was created.
  Future<bool> stashPush(String worktreePath, {bool includeUntracked = true});

  /// Pops the top stash entry.
  Future<void> stashPop(String worktreePath);

  /// Drops a stash entry.
  Future<void> stashDrop(String worktreePath, {int index = 0});

  /// Merges [ref] into the current branch.
  Future<void> merge(
    String worktreePath, {
    required String ref,
    required WorkflowGitMergeStrategy strategy,
    String? message,
  });

  /// Aborts an in-progress merge.
  Future<void> mergeAbort(String worktreePath);

  /// Resets the worktree hard to [ref].
  Future<void> resetHard(String worktreePath, String ref);
}

/// Merge strategy understood by [WorkflowGitPort].
enum WorkflowGitMergeStrategy { squash, merge }

/// Parsed `git status --porcelain` state.
final class GitStatus {
  /// Whether tracked index/worktree entries are clean.
  final bool indexClean;

  /// Tracked or staged paths with modifications.
  final List<String> modified;

  /// Untracked paths.
  final List<String> untracked;

  const GitStatus({required this.indexClean, required this.modified, required this.untracked});
}

/// Commit created by [WorkflowGitPort.commit].
final class WorkflowGitCommit {
  /// SHA of the resulting `HEAD`.
  final String sha;

  /// Commit message supplied by the caller.
  final String message;

  const WorkflowGitCommit({required this.sha, required this.message});
}

/// Git operation failed below [WorkflowGitPort].
final class WorkflowGitException implements Exception {
  /// Human-readable failure message.
  final String message;

  /// Git arguments used for the failing operation.
  final List<String> args;

  /// Captured stdout.
  final String stdout;

  /// Captured stderr.
  final String stderr;

  /// Process exit code.
  final int? exitCode;

  const WorkflowGitException(
    this.message, {
    this.args = const <String>[],
    this.stdout = '',
    this.stderr = '',
    this.exitCode,
  });

  @override
  String toString() {
    final detail = stderr.isNotEmpty ? stderr : stdout;
    final suffix = detail.isEmpty ? '' : ': $detail';
    return 'WorkflowGitException: $message$suffix';
  }
}
