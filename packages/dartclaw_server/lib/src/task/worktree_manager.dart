import 'dart:io';

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
    required String projectDir,
    String baseRef = 'main',
    int staleTimeoutHours = 24,
    String? worktreesDir,
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
    processRunner,
  }) : _projectDir = projectDir,
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
  /// 1. Verifies git is available (cached check)
  /// 2. Creates branch `dartclaw/task-<taskId>` from [baseRef]
  ///    - Appends `-N` suffix on collision
  /// 3. Runs `git worktree add <path> <branch>`
  /// 4. Returns [WorktreeInfo] with path, branch, and creation timestamp
  ///
  /// Throws [GitNotFoundException] if git is not available.
  /// Throws [WorktreeException] on git failure (with stderr output).
  Future<WorktreeInfo> create(String taskId, {String? baseRef}) async {
    await _ensureGitAvailable();

    final ref = baseRef ?? _baseRef;
    final branch = await _resolveBranchName(taskId);
    final worktreePath = p.join(_worktreesDir, taskId);

    // Create parent directory
    await Directory(_worktreesDir).create(recursive: true);

    // Create the branch from base ref
    final branchResult = await _runProcess('git', ['branch', branch, ref], workingDirectory: _projectDir);
    if (branchResult.exitCode != 0) {
      throw WorktreeException(
        'Failed to create branch $branch from $ref',
        gitStderr: (branchResult.stderr as String).trim(),
        exitCode: branchResult.exitCode,
      );
    }

    // Create the worktree
    final worktreeResult = await _runProcess('git', [
      'worktree',
      'add',
      worktreePath,
      branch,
    ], workingDirectory: _projectDir);
    if (worktreeResult.exitCode != 0) {
      // Clean up the branch if worktree creation fails
      await _runProcess('git', ['branch', '--delete', branch], workingDirectory: _projectDir);
      throw WorktreeException(
        'Failed to create worktree at $worktreePath',
        gitStderr: (worktreeResult.stderr as String).trim(),
        exitCode: worktreeResult.exitCode,
      );
    }

    final info = WorktreeInfo(path: worktreePath, branch: branch, createdAt: DateTime.now());
    _worktrees[taskId] = info;
    _log.info('Created worktree for task $taskId at $worktreePath (branch: $branch)');
    return info;
  }

  /// Removes worktree directory and deletes the branch.
  ///
  /// Logs warnings on failure but does not throw — cleanup is best-effort.
  Future<void> cleanup(String taskId) async {
    final info = _worktrees[taskId];
    final worktreePath = info?.path ?? p.join(_worktreesDir, taskId);
    final branch = info?.branch ?? 'dartclaw/task-$taskId';

    // Remove worktree
    final removeResult = await _runProcess('git', ['worktree', 'remove', worktreePath], workingDirectory: _projectDir);
    if (removeResult.exitCode != 0) {
      _log.warning(
        'Failed to remove worktree for task $taskId: '
        '${(removeResult.stderr as String).trim()}',
      );
    }

    // Delete branch
    final branchResult = await _runProcess('git', ['branch', '--delete', branch], workingDirectory: _projectDir);
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
  Future<String> _resolveBranchName(String taskId) async {
    final base = 'dartclaw/task-$taskId';

    if (!await _branchExists(base)) return base;

    for (var i = 2; i <= 100; i++) {
      final candidate = '$base-$i';
      if (!await _branchExists(candidate)) return candidate;
    }

    throw WorktreeException('Could not find available branch name for task $taskId');
  }

  Future<bool> _branchExists(String branchName) async {
    final result = await _runProcess('git', ['branch', '--list', branchName], workingDirectory: _projectDir);
    return (result.stdout as String).trim().isNotEmpty;
  }
}
