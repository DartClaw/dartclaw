import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show secureWriteFileSync;
import 'package:logging/logging.dart';

/// Version-controls the workspace directory via git.
///
/// Auto-initializes the repo, commits outstanding changes, and optionally
/// pushes to a configured remote.
/// `pushEnabled` is written by exactly one authority, [RuntimeToggleApplier];
/// this class holds the value and never reacts to config itself. It used to
/// implement [Reconfigurable] on `workspace.*` and write the field directly,
/// which silently reverted an ephemeral push toggle and left the value
/// `GET /api/settings/runtime` reports disagreeing with the one in force.
class WorkspaceGitSync {
  static final _log = Logger('WorkspaceGitSync');

  static const defaultGitignore = '.env\n*.key\n*.pem\nsecrets*\n.DS_Store\nerrors.md\n';

  final String workspaceDir;
  bool pushEnabled;
  final GitRunner _runGit;

  // Workspace git spawns keep system git config in band. Outlier under the
  // automation-owned vs user-visible split the security architecture doc
  // records; flipping it is a behaviour change, not a dedup.
  static const _noSystemConfig = false;
  bool _gitAvailable = false;

  new({required this.workspaceDir, this.pushEnabled = true, GitRunner? commandRunner})
    : _runGit = commandRunner ?? runGit;

  bool get gitAvailable => _gitAvailable;

  /// Check if git is available on PATH.
  Future<bool> isGitAvailable() async {
    try {
      final result = await _runGit(const ['--version'], noSystemConfig: _noSystemConfig);
      _gitAvailable = result.exitCode == 0;
      if (!_gitAvailable) _log.warning('git not found — workspace sync disabled');
      return _gitAvailable;
    } catch (e) {
      _log.warning('git not available: $e — workspace sync disabled');
      _gitAvailable = false;
      return false;
    }
  }

  /// Initialize git repo if not already initialized.
  Future<void> initIfNeeded() async {
    if (!_gitAvailable) return;

    Directory(workspaceDir).createSync(recursive: true);
    final gitMetadataPath = '$workspaceDir/.git';
    final repoExists = FileSystemEntity.typeSync(gitMetadataPath, followLinks: false) != FileSystemEntityType.notFound;

    if (!repoExists) {
      _log.info('Initializing git repo in workspace');

      final init = await _git(['init']);
      if (init.exitCode != 0) {
        _log.warning('git init failed: ${init.stderr}');
        return;
      }
    }

    _ensureDefaultGitignore();

    if (repoExists) return;

    await commitAll(message: 'DartClaw workspace initialized');
  }

  void _ensureDefaultGitignore() {
    final gitignore = File('$workspaceDir/.gitignore');
    try {
      final entityType = FileSystemEntity.typeSync(gitignore.path, followLinks: false);
      if (entityType == FileSystemEntityType.notFound) {
        secureWriteFileSync(gitignore, defaultGitignore, restrictPermissions: false);
        return;
      }
      if (entityType != FileSystemEntityType.file) {
        _log.warning('Workspace .gitignore is not a regular file — default exclusions not applied');
        return;
      }

      final content = gitignore.readAsStringSync();
      final existing = const LineSplitter().convert(content).toSet();
      final missing = defaultGitignore
          .split('\n')
          .where((entry) => entry.isNotEmpty && !existing.contains(entry))
          .toList();
      if (missing.isEmpty) return;

      secureWriteFileSync(gitignore, '${missing.join('\n')}\n$content', restrictPermissions: false);
    } on FileSystemException catch (e) {
      _log.warning('Workspace .gitignore defaults not applied: ${e.message}');
    } on FormatException catch (e) {
      _log.warning('Workspace .gitignore defaults not applied: ${e.message}');
    }
  }

  /// Commit all changes with a timestamp message. No-op if no changes.
  Future<bool> commitAll({String? message}) async {
    if (!_gitAvailable) return false;

    // Check for changes
    final status = await _git(['status', '--porcelain']);
    if (status.exitCode != 0) {
      _log.warning('git status failed: ${status.stderr}');
      return false;
    }

    final output = (status.stdout as String).trim();
    if (output.isEmpty) return false;

    // Stage all
    final add = await _git(['add', '.']);
    if (add.exitCode != 0) {
      _log.warning('git add failed: ${add.stderr}');
      return false;
    }

    // Commit
    final msg = message ?? 'DartClaw auto-commit: ${DateTime.now().toUtc().toIso8601String()}';
    final commit = await _git(['commit', '-m', msg]);
    if (commit.exitCode != 0) {
      _log.warning('git commit failed: ${commit.stderr}');
      return false;
    }

    _log.fine('Committed workspace changes');
    return true;
  }

  /// Push to origin if remote exists and pushEnabled.
  Future<bool> push() async {
    if (!_gitAvailable || !pushEnabled) return true;

    // Check if origin remote exists
    final remote = await _git(['remote', 'get-url', 'origin']);
    if (remote.exitCode != 0) return true; // no remote, skip silently

    final pushResult = await _git(['push']);
    if (pushResult.exitCode != 0) {
      _log.warning('git push failed: ${pushResult.stderr} — will retry next cycle');
      return false;
    }

    _log.fine('Pushed workspace to origin');
    return true;
  }

  /// Combined: commit, then push when a remote is configured and pushing is enabled.
  Future<void> commitAndPush() async {
    try {
      await commitAll();
      await push();
    } catch (e) {
      _log.warning('Git sync failed: $e');
    }
  }

  Future<ProcessResult> _git(List<String> args) async {
    return _runGit(args, workingDirectory: workspaceDir, noSystemConfig: _noSystemConfig);
  }
}
