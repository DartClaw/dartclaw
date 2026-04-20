import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:dartclaw_models/dartclaw_models.dart' show Project;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'git_credential_env.dart';

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

final class _RegisteredWorktree {
  final String path;
  final String? branch;

  const _RegisteredWorktree({required this.path, required this.branch});
}

/// Git worktree lifecycle manager for coding tasks.
///
/// Worktrees are keyed by the caller-supplied `taskId`, which must be globally
/// unique (UUID v4). Never introduce path derivation from shared-identity
/// fields — doing so would re-open the cross-run contamination class that
/// DartClaw's UUID-keyed design currently prevents by construction.
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

  final String? _projectDir;
  final String _baseRef;
  final int _staleTimeoutHours;
  final String _worktreesDir;
  final Map<String, WorktreeInfo> _worktrees = {};
  final Future<Task?> Function(String taskId)? _taskLookup;
  final Future<Project?> Function(String projectId)? _projectLookup;

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
    Future<Task?> Function(String taskId)? taskLookup,
    Future<Project?> Function(String projectId)? projectLookup,
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
    processRunner,
  }) : _projectDir = projectDir,
       _baseRef = baseRef,
       _staleTimeoutHours = staleTimeoutHours,
       _worktreesDir = worktreesDir ?? p.join(dataDir, 'worktrees'),
       _taskLookup = taskLookup,
       _projectLookup = projectLookup,
       _runProcess = processRunner ?? _defaultProcessRunner;

  // All git spawns routed through the default runner carry
  // `GIT_CONFIG_NOSYSTEM=1`. Worktree setup/cleanup performs a checkout, so
  // system-level git config (hooks, filters, sshCommand) remains in-band for
  // the child unless this flag neutralizes it. Injected runners bypass this
  // default and are expected to set their own policy.
  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    if (executable == 'git') {
      return SafeProcess.git(
        arguments,
        plan: const GitCredentialPlan.none(),
        workingDirectory: workingDirectory,
        noSystemConfig: true,
      );
    }
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
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    await _ensureGitAvailable();

    final effectiveProjectDir = project?.localPath ?? _defaultProjectDir;
    final worktreePath = p.join(_worktreesDir, taskId);
    final persistedInfo = _parseWorktreeInfo(existingWorktreeJson);

    // Create parent directory
    await Directory(_worktreesDir).create(recursive: true);

    final adopted = await _reconcileExistingState(
      taskId: taskId,
      worktreePath: worktreePath,
      workingDirectory: effectiveProjectDir,
      createBranch: createBranch,
      attachedBranch: _trimmedOrNull(baseRef),
      persistedInfo: persistedInfo,
    );
    if (adopted != null) {
      return adopted;
    }

    final branch = createBranch
        ? await _resolveBranchName(taskId, projectDir: effectiveProjectDir)
        : (_trimmedOrNull(baseRef) ??
              persistedInfo?.branch ??
              await _resolveBranchName(taskId, projectDir: effectiveProjectDir));

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
    final effectiveProjectDir = project?.localPath ?? _defaultProjectDir;

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
      if (!stat.changed.isBefore(threshold)) {
        continue;
      }

      final taskId = p.basename(entity.path);
      final lookup = _taskLookup;
      if (lookup == null) {
        _log.warning(
          'Stale worktree detected: $taskId (created ${stat.changed.toIso8601String()}, '
          'threshold: ${_staleTimeoutHours}h) — task lookup unavailable, leaving in place',
        );
        continue;
      }

      final task = await lookup(taskId);
      final confirmedOrphan = task == null || task.status.terminal;
      if (!confirmedOrphan) {
        _log.warning(
          'Stale worktree detected: $taskId (created ${stat.changed.toIso8601String()}, '
          'threshold: ${_staleTimeoutHours}h) — owning task ${task.id} is ${task.status.name}, leaving in place',
        );
        continue;
      }

      try {
        final reapWorkingDir = await _resolveReapWorkingDirectory(task);
        await _reapWorktreePath(entity.path, workingDirectory: reapWorkingDir);
        _worktrees.remove(taskId);
        _log.info(
          'Reaped stale worktree $taskId at ${entity.path} '
          '(owning task ${task == null ? "missing" : task.status.name}, '
          'repo: $reapWorkingDir, threshold: ${_staleTimeoutHours}h)',
        );
      } catch (error) {
        _log.warning('Failed to reap stale worktree $taskId at ${entity.path}; leaving in place: $error');
      }
    }
  }

  /// Returns worktree info for a task, or null if no worktree exists.
  WorktreeInfo? getWorktreeInfo(String taskId) => _worktrees[taskId];

  /// Applies an `externalArtifactMount` instruction to a worktree that has
  /// already been created.
  ///
  /// Two modes are supported:
  ///
  /// - `per-story-copy` (default, least-privilege): copy exactly one file from
  ///   the [fromProjectDir]'s workspace at [relativeSourcePath] into the
  ///   [worktree] at the same relative path. Parent directories are created
  ///   as needed. The file is the only content sourced from `fromProject` —
  ///   no sibling stories' artifacts are reachable from inside the worktree.
  ///
  /// - `bind-mount`: currently unsupported at the library level (requires
  ///   platform-specific mount privileges). Throws [WorktreeException] when
  ///   invoked with this mode so callers fall back to per-story-copy or
  ///   surface the limitation.
  ///
  /// Returns the absolute path of the file written inside the worktree on
  /// success. Safe to call multiple times — a second call with identical
  /// content is a no-op; a call with different content overwrites.
  Future<String> applyExternalArtifactMount({
    required WorktreeInfo worktree,
    required String fromProjectDir,
    required String relativeSourcePath,
    String mode = 'per-story-copy',
  }) async {
    if (mode == 'bind-mount') {
      throw const WorktreeException(
        'externalArtifactMount mode "bind-mount" is not supported by '
        'WorktreeManager on this platform; use mode: "per-story-copy" instead '
        'or implement a platform-specific mount provider.',
      );
    }
    if (mode != 'per-story-copy') {
      throw WorktreeException(
        'externalArtifactMount: unknown mode "$mode" (expected "per-story-copy" or "bind-mount")',
      );
    }
    final normalized = p.normalize(relativeSourcePath);
    if (normalized.startsWith('..') || p.isAbsolute(normalized)) {
      throw WorktreeException(
        'externalArtifactMount: source path "$relativeSourcePath" must be a '
        'workspace-relative path that stays inside fromProject',
      );
    }
    final sourceFile = File(p.join(fromProjectDir, normalized));
    if (!sourceFile.existsSync()) {
      throw WorktreeException('externalArtifactMount: source file missing — $fromProjectDir/$normalized');
    }
    final targetFile = File(p.join(worktree.path, normalized));
    await targetFile.parent.create(recursive: true);
    if (targetFile.existsSync()) {
      final existingHash = sha256.convert(targetFile.readAsBytesSync()).toString();
      final sourceHash = sha256.convert(sourceFile.readAsBytesSync()).toString();
      if (existingHash != sourceHash) {
        _log.warning(
          'externalArtifactMount target already exists with different content: '
          '${targetFile.path} (existing ${existingHash.substring(0, 8)}, '
          'incoming ${sourceHash.substring(0, 8)}). Overwriting.',
        );
      }
    }
    await sourceFile.copy(targetFile.path);
    _log.info('externalArtifactMount: copied $normalized from $fromProjectDir into worktree ${worktree.path}');
    return targetFile.path;
  }

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
    ], workingDirectory: projectDir ?? _defaultProjectDir);
    return (result.stdout as String).trim().isNotEmpty;
  }

  WorktreeInfo? _parseWorktreeInfo(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      return WorktreeInfo.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<WorktreeInfo?> _reconcileExistingState({
    required String taskId,
    required String worktreePath,
    required String workingDirectory,
    required bool createBranch,
    required String? attachedBranch,
    required WorktreeInfo? persistedInfo,
  }) async {
    final inMemory = _worktrees[taskId];
    final registered = await _registeredWorktreeForPath(worktreePath, workingDirectory: workingDirectory);
    final dirExists = Directory(worktreePath).existsSync();

    if (inMemory != null &&
        dirExists &&
        registered != null &&
        _samePath(inMemory.path, worktreePath) &&
        _samePath(registered.path, worktreePath) &&
        registered.branch == inMemory.branch) {
      return inMemory;
    }

    if (dirExists && registered != null) {
      final expectedInfo = persistedInfo ?? inMemory;
      final expectedPath = expectedInfo?.path ?? worktreePath;
      final expectedBranch = expectedInfo?.branch ?? attachedBranch ?? registered.branch;
      if (_samePath(expectedPath, worktreePath) &&
          _samePath(registered.path, worktreePath) &&
          expectedBranch != null &&
          registered.branch == expectedBranch) {
        final adopted =
            expectedInfo ?? WorktreeInfo(path: worktreePath, branch: expectedBranch, createdAt: DateTime.now());
        _worktrees[taskId] = adopted;
        _log.info('Adopted existing worktree for task $taskId at $worktreePath (branch: ${adopted.branch})');
        return adopted;
      }

      await _removeRegisteredWorktree(worktreePath, workingDirectory: workingDirectory);
      await _deleteDirectoryIfExists(worktreePath);
      return null;
    }

    if (dirExists && registered == null) {
      await _deleteDirectoryIfExists(worktreePath);
      return null;
    }

    if (!dirExists && registered != null) {
      await _pruneDanglingWorktrees(workingDirectory);
    }
    return null;
  }

  Future<_RegisteredWorktree?> _registeredWorktreeForPath(
    String worktreePath, {
    required String workingDirectory,
  }) async {
    final entries = await _listRegisteredWorktrees(workingDirectory: workingDirectory);
    for (final entry in entries) {
      if (_samePath(entry.path, worktreePath)) {
        return entry;
      }
    }
    return null;
  }

  Future<List<_RegisteredWorktree>> _listRegisteredWorktrees({required String workingDirectory}) async {
    final result = await _runProcess('git', ['worktree', 'list', '--porcelain'], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw WorktreeException(
        'Failed to list git worktrees',
        gitStderr: (result.stderr as String).trim(),
        exitCode: result.exitCode,
      );
    }

    final lines = (result.stdout as String).split('\n');
    final entries = <_RegisteredWorktree>[];
    String? currentPath;
    String? currentBranch;
    void flush() {
      if (currentPath != null) {
        entries.add(_RegisteredWorktree(path: currentPath!, branch: currentBranch));
      }
      currentPath = null;
      currentBranch = null;
    }

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        flush();
        continue;
      }
      if (trimmed.startsWith('worktree ')) {
        currentPath = trimmed.substring('worktree '.length);
        continue;
      }
      if (trimmed.startsWith('branch ')) {
        final rawBranch = trimmed.substring('branch '.length);
        currentBranch = rawBranch.startsWith('refs/heads/') ? rawBranch.substring('refs/heads/'.length) : rawBranch;
      }
    }
    flush();
    return entries;
  }

  Future<void> _removeRegisteredWorktree(String worktreePath, {required String workingDirectory}) async {
    final result = await _runProcess('git', [
      'worktree',
      'remove',
      '--force',
      worktreePath,
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw WorktreeException(
        'Failed to remove registered worktree at $worktreePath',
        gitStderr: (result.stderr as String).trim(),
        exitCode: result.exitCode,
      );
    }
  }

  Future<void> _pruneDanglingWorktrees(String workingDirectory) async {
    final result = await _runProcess('git', ['worktree', 'prune'], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw WorktreeException(
        'Failed to prune dangling worktrees',
        gitStderr: (result.stderr as String).trim(),
        exitCode: result.exitCode,
      );
    }
  }

  /// Picks the git working directory for reaping a stale worktree.
  ///
  /// Stale worktrees may belong to projects other than the default repo. When
  /// the owning task has a `projectId` and a project lookup is available,
  /// prefer the owning project's local clone so `git worktree remove`
  /// unregisters the worktree from the repo that actually tracks it. Falls
  /// back to the default project directory when the owning repo can't be
  /// resolved (e.g. task row missing, `_local`, or lookup unavailable).
  ///
  /// Limitation: when the task row is missing (true orphan), the owning
  /// project cannot be recovered because worktree paths are UUID-keyed and do
  /// not encode `projectId`. The fallback to `_defaultProjectDir` may leave a
  /// dangling worktree registration in the real owning repo; disk cleanup
  /// still succeeds. Encoding `projectId` in the worktree path would close
  /// this residual gap but is out of scope here.
  Future<String> _resolveReapWorkingDirectory(Task? task) async {
    final projectLookup = _projectLookup;
    final projectId = task?.projectId;
    if (projectLookup == null || projectId == null || projectId.isEmpty || projectId == '_local') {
      return _defaultProjectDir;
    }
    try {
      final project = await projectLookup(projectId);
      final localPath = project?.localPath;
      if (localPath == null || localPath.isEmpty) {
        return _defaultProjectDir;
      }
      return localPath;
    } catch (error) {
      _log.warning('Failed to resolve project $projectId for stale reap; using default repo: $error');
      return _defaultProjectDir;
    }
  }

  Future<void> _reapWorktreePath(String worktreePath, {required String workingDirectory}) async {
    final registered = await _registeredWorktreeForPath(worktreePath, workingDirectory: workingDirectory);
    if (registered != null) {
      await _removeRegisteredWorktree(worktreePath, workingDirectory: workingDirectory);
    }
    await _deleteDirectoryIfExists(worktreePath);
  }

  Future<void> _deleteDirectoryIfExists(String path) async {
    final directory = Directory(path);
    if (!directory.existsSync()) return;
    await directory.delete(recursive: true);
  }

  bool _samePath(String left, String right) => p.normalize(left) == p.normalize(right);

  String? _trimmedOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String get _defaultProjectDir => _projectDir ?? Directory.current.path;
}
