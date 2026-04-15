import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show Project;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Metadata about a created git worktree.
class WorktreeInfo {
  final String path;
  final String branch;
  final DateTime createdAt;

  const WorktreeInfo({required this.path, required this.branch, required this.createdAt});

  Map<String, dynamic> toJson() => {'path': path, 'branch': branch, 'createdAt': createdAt.toIso8601String()};

  factory WorktreeInfo.fromJson(Map<String, dynamic> json) => WorktreeInfo(
    path: json['path'] as String,
    branch: json['branch'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// Thrown when a git worktree operation fails.
class WorktreeException implements Exception {
  final String message;
  final String? gitStderr;
  final int? exitCode;

  const WorktreeException(this.message, {this.gitStderr, this.exitCode});

  @override
  String toString() {
    final buffer = StringBuffer('WorktreeException: $message');
    if (gitStderr != null && gitStderr!.isNotEmpty) {
      buffer.write('\ngit stderr: $gitStderr');
    }
    if (exitCode != null) {
      buffer.write(' (exit code: $exitCode)');
    }
    return buffer.toString();
  }
}

/// Thrown when git is not available on the system.
class GitNotFoundException implements Exception {
  @override
  String toString() => 'GitNotFoundException: git is not installed or not in PATH';
}

/// Git worktree lifecycle manager for coding tasks.
///
/// Creates isolated git worktrees with dedicated branches, giving each coding
/// task a sandboxed working directory. On task completion, the worktree and
/// branch are cleaned up. On failure, preserved for inspection.
///
/// When a [Project] is passed to [create], the worktree is created from the
/// project's clone directory using `origin/<defaultBranch>` as the start point.
/// When no project is provided, the constructor-supplied [projectDir] and
/// [baseRef] are used (backward-compatible default behavior).
class WorktreeManager {
  static final _log = Logger('WorktreeManager');

  final String _projectDir;
  final String _baseRef;
  final int _staleTimeoutHours;
  final String _worktreesDir;
  final Map<String, WorktreeInfo> _worktrees = {};

  bool? _gitAvailable;

  /// Injectable process runner for testing.
  final Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})
  _runProcess;

  WorktreeManager({
    required String dataDir,
    String? projectDir,
    String baseRef = 'main',
    int staleTimeoutHours = 24,
    String? worktreesDir,
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
    processRunner,
  }) : _projectDir = projectDir ?? Directory.current.path,
       _baseRef = baseRef,
       _staleTimeoutHours = staleTimeoutHours,
       _worktreesDir = worktreesDir ?? p.join(dataDir, 'worktrees'),
       _runProcess = processRunner ?? _defaultProcessRunner;

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    return Process.run(executable, arguments, workingDirectory: workingDirectory);
  }

  /// Creates a new git worktree for the given task.
  ///
  /// When [project] is provided, the worktree is created from the project's
  /// clone directory using `origin/<defaultBranch>` as the start point, via a
  /// single-step `git worktree add <path> -b <branch> origin/<branch>` command.
  ///
  /// When [project] is null, falls back to the constructor-provided defaults:
  /// two-step `git branch` + `git worktree add` from the local base ref.
  ///
  /// Throws [GitNotFoundException] if git is not available.
  /// Throws [WorktreeException] on git failure (with stderr output).
  Future<WorktreeInfo> create(String taskId, {String? baseRef, Project? project, bool createBranch = true}) async {
    await _ensureGitAvailable();

    final effectiveProjectDir = project?.localPath ?? _projectDir;
    final branch = await _resolveBranchName(taskId, projectDir: effectiveProjectDir);
    final worktreePath = p.join(_worktreesDir, taskId);

    // Create parent directory
    await Directory(_worktreesDir).create(recursive: true);

    if (project != null) {
      // Project-backed: create from remote tracking ref by default.
      final hasExplicitBaseRef = baseRef != null && baseRef.trim().isNotEmpty;
      final requestedBaseRef = hasExplicitBaseRef ? baseRef.trim() : 'origin/${project.defaultBranch}';
      final effectiveBaseRef = await _resolveProjectBaseRef(
        requestedBaseRef: requestedBaseRef,
        defaultBranch: project.defaultBranch,
        workingDirectory: effectiveProjectDir,
        preserveLocalRef: hasExplicitBaseRef,
      );
      final args = createBranch
          ? ['worktree', 'add', worktreePath, '-b', branch, effectiveBaseRef]
          : ['worktree', 'add', worktreePath, effectiveBaseRef];
      final worktreeResult = await _runProcess('git', args, workingDirectory: effectiveProjectDir);
      if (worktreeResult.exitCode != 0) {
        throw WorktreeException(
          'Failed to create worktree at $worktreePath',
          gitStderr: (worktreeResult.stderr as String).trim(),
          exitCode: worktreeResult.exitCode,
        );
      }
      if (!createBranch) {
        _log.info('Attached worktree $worktreePath to existing ref $effectiveBaseRef');
      }
    } else {
      // Local fallback: two-step branch + worktree creation.
      final ref = baseRef ?? _baseRef;
      if (createBranch) {
        final branchResult = await _runProcess('git', ['branch', branch, ref], workingDirectory: effectiveProjectDir);
        if (branchResult.exitCode != 0) {
          throw WorktreeException(
            'Failed to create branch $branch from $ref',
            gitStderr: (branchResult.stderr as String).trim(),
            exitCode: branchResult.exitCode,
          );
        }
      }
      final worktreeArgs = createBranch
          ? ['worktree', 'add', worktreePath, branch]
          : ['worktree', 'add', worktreePath, ref];
      final worktreeResult = await _runProcess('git', worktreeArgs, workingDirectory: effectiveProjectDir);
      if (worktreeResult.exitCode != 0) {
        if (createBranch) {
          // Clean up the branch if worktree creation fails
          await _runProcess('git', ['branch', '--delete', branch], workingDirectory: effectiveProjectDir);
        }
        throw WorktreeException(
          'Failed to create worktree at $worktreePath',
          gitStderr: (worktreeResult.stderr as String).trim(),
          exitCode: worktreeResult.exitCode,
        );
      }
    }

    final info = WorktreeInfo(
      path: worktreePath,
      branch: createBranch ? branch : ((baseRef != null && baseRef.trim().isNotEmpty) ? baseRef.trim() : branch),
      createdAt: DateTime.now(),
    );
    _worktrees[taskId] = info;
    _log.info(
      'Created worktree for task $taskId at $worktreePath '
      '(branch: $branch, project: ${project?.id ?? "_local"})',
    );
    return info;
  }

  Future<String> _resolveProjectBaseRef({
    required String requestedBaseRef,
    required String defaultBranch,
    required String workingDirectory,
    required bool preserveLocalRef,
  }) async {
    final ref = requestedBaseRef;
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return 'origin/$defaultBranch';
    if (trimmed.startsWith('origin/') || trimmed.startsWith('refs/')) return trimmed;
    if (preserveLocalRef && trimmed != defaultBranch && await _localRefExists(trimmed, workingDirectory)) {
      return trimmed;
    }
    return 'origin/$trimmed';
  }

  Future<bool> _localRefExists(String ref, String workingDirectory) async {
    final result = await _runProcess('git', [
      'rev-parse',
      '--verify',
      '--quiet',
      ref,
    ], workingDirectory: workingDirectory);
    return result.exitCode == 0;
  }

  /// Removes worktree directory and deletes the branch.
  ///
  /// When [project] is provided, uses the project's [localPath] as the git
  /// working directory for removal. Falls back to the constructor-provided
  /// [projectDir] when [project] is null.
  ///
  /// Logs warnings on failure but does not throw — cleanup is best-effort.
  Future<void> cleanup(String taskId, {Project? project}) async {
    final info = _worktrees[taskId];
    final worktreePath = info?.path ?? p.join(_worktreesDir, taskId);
    final branch = info?.branch ?? 'dartclaw/task-$taskId';
    final effectiveProjectDir = project?.localPath ?? _projectDir;

    // Remove worktree
    final removeResult = await _runProcess('git', [
      'worktree',
      'remove',
      worktreePath,
    ], workingDirectory: effectiveProjectDir);
    if (removeResult.exitCode != 0) {
      _log.warning(
        'Failed to remove worktree for task $taskId: '
        '${(removeResult.stderr as String).trim()}',
      );
    }

    // Delete branch
    final branchResult = await _runProcess('git', [
      'branch',
      '--delete',
      branch,
    ], workingDirectory: effectiveProjectDir);
    if (branchResult.exitCode != 0) {
      _log.warning(
        'Failed to delete branch $branch for task $taskId: '
        '${(branchResult.stderr as String).trim()}',
      );
    }

    _worktrees.remove(taskId);
    _log.info('Cleaned up worktree for task $taskId');
  }

  /// Checks all worktrees in `<dataDir>/worktrees/` and logs warnings
  /// for any older than [_staleTimeoutHours].
  Future<void> detectStaleWorktrees() async {
    final dir = Directory(_worktreesDir);
    if (!dir.existsSync()) return;

    final threshold = DateTime.now().subtract(Duration(hours: _staleTimeoutHours));

    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final stat = await entity.stat();
      if (stat.changed.isBefore(threshold)) {
        final taskId = p.basename(entity.path);
        _log.warning(
          'Stale worktree detected: $taskId (created ${stat.changed.toIso8601String()}, '
          'threshold: ${_staleTimeoutHours}h)',
        );
      }
    }
  }

  /// Returns worktree info for a task, or null if no worktree exists.
  WorktreeInfo? getWorktreeInfo(String taskId) => _worktrees[taskId];

  Future<void> _ensureGitAvailable() async {
    if (_gitAvailable == true) return;
    if (_gitAvailable == false) throw GitNotFoundException();

    final result = await _runProcess('git', ['--version']);
    if (result.exitCode != 0) {
      _gitAvailable = false;
      throw GitNotFoundException();
    }
    _gitAvailable = true;
  }

  /// Derives a unique branch name, appending `-N` suffix on collision.
  Future<String> _resolveBranchName(String taskId, {String? projectDir}) async {
    final base = 'dartclaw/task-$taskId';

    if (!await _branchExists(base, projectDir: projectDir)) return base;

    for (var i = 2; i <= 100; i++) {
      final candidate = '$base-$i';
      if (!await _branchExists(candidate, projectDir: projectDir)) return candidate;
    }

    throw WorktreeException('Could not find available branch name for task $taskId');
  }

  Future<bool> _branchExists(String branchName, {String? projectDir}) async {
    final result = await _runProcess('git', [
      'branch',
      '--list',
      branchName,
    ], workingDirectory: projectDir ?? _projectDir);
    return (result.stdout as String).trim().isNotEmpty;
  }
}
