import 'dart:io';

import 'package:logging/logging.dart';

/// Callback for running shell commands (injectable for tests).
typedef CommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory});

/// Version-controls the workspace directory via git.
///
/// Auto-initializes the repo, commits changes on heartbeat, and optionally
/// pushes to a configured remote.
class WorkspaceGitSync {
  static final _log = Logger('WorkspaceGitSync');

  static const defaultGitignore = '.env\n*.key\n*.pem\nsecrets*\n.DS_Store\nerrors.md\nlearnings.md\n';

  final String workspaceDir;
  bool pushEnabled;
  final CommandRunner _run;
  bool _gitAvailable = false;

  WorkspaceGitSync({required this.workspaceDir, this.pushEnabled = true, CommandRunner? commandRunner})
    : _run = commandRunner ?? _defaultRunner;

  bool get gitAvailable => _gitAvailable;

  /// Check if git is available on PATH.
  Future<bool> isGitAvailable() async {
    try {
      final result = await _run('git', ['--version']);
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

    final gitDir = Directory('$workspaceDir/.git');
    if (gitDir.existsSync()) return;

    _log.info('Initializing git repo in workspace');

    final init = await _git(['init']);
    if (init.exitCode != 0) {
      _log.warning('git init failed: ${init.stderr}');
      return;
    }

    // Create .gitignore if not exists
    final gitignore = File('$workspaceDir/.gitignore');
    if (!gitignore.existsSync()) {
      gitignore.writeAsStringSync(defaultGitignore);
    }

    // Initial commit
    await commitAll(message: 'DartClaw workspace initialized');
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

  /// Combined: commit + push. Called by heartbeat.
  Future<void> commitAndPush() async {
    try {
      await commitAll();
      await push();
    } catch (e) {
      _log.warning('Git sync failed: $e');
    }
  }

  Future<ProcessResult> _git(List<String> args) async {
    return _run('git', args, workingDirectory: workspaceDir);
  }

  static Future<ProcessResult> _defaultRunner(String executable, List<String> arguments, {String? workingDirectory}) {
    return Process.run(executable, arguments, workingDirectory: workingDirectory);
  }
}
