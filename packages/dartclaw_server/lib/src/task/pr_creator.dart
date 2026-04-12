import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:dartclaw_models/dartclaw_models.dart' show Project;
import 'package:logging/logging.dart';

/// Result of a PR creation attempt.
sealed class PrCreationResult {
  const PrCreationResult();
}

/// PR was created successfully.
final class PrCreated extends PrCreationResult {
  /// The URL of the newly created PR.
  final String url;

  const PrCreated(this.url);
}

/// `gh` CLI was not found on PATH; manual instructions provided.
final class PrGhNotFound extends PrCreationResult {
  /// Human-readable instructions for creating the PR manually.
  final String instructions;

  const PrGhNotFound(this.instructions);
}

/// `gh pr create` was invoked but failed.
final class PrCreationFailed extends PrCreationResult {
  final String error;
  final String details;

  const PrCreationFailed({required this.error, required this.details});
}

/// Creates GitHub pull requests via the `gh` CLI.
///
/// Uses the outpost pattern: invokes `gh pr create` as a subprocess.
/// Gracefully degrades when `gh` is not available on PATH.
class PrCreator {
  static final _log = Logger('PrCreator');

  /// Cached result of the `gh` availability check.
  bool? _ghAvailable;

  /// Injectable process runner for testing.
  final Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
  _processRunner;

  PrCreator({
    Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})?
    processRunner,
  }) : _processRunner = processRunner;

  /// Creates a GitHub PR for the given [branch].
  ///
  /// Returns [PrGhNotFound] if the `gh` CLI is not on PATH.
  /// Returns [PrCreated] with the PR URL on success.
  /// Returns [PrCreationFailed] on any `gh` error.
  Future<PrCreationResult> create({required Project project, required Task task, required String branch}) async {
    if (!await _ensureGhAvailable()) {
      return PrGhNotFound(_manualPrInstructions(project, branch));
    }

    final args = [
      'pr',
      'create',
      '--title',
      task.title,
      '--body',
      _buildPrBody(task),
      '--head',
      branch,
      '--base',
      project.defaultBranch,
    ];

    if (project.pr.draft) args.add('--draft');
    for (final label in project.pr.labels) {
      args.addAll(['--label', label]);
    }

    try {
      final result = await _run('gh', args, workingDirectory: project.localPath);
      final stdout = result.stdout as String;
      final stderr = result.stderr as String;

      if (result.exitCode == 0) {
        final url = stdout.trim().split('\n').firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
        _log.info('PR created for branch $branch: $url');
        return PrCreated(url);
      }

      _log.warning('gh pr create failed (exit ${result.exitCode}): $stderr');
      return PrCreationFailed(
        error: 'gh pr create failed with exit code ${result.exitCode}',
        details: stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim(),
      );
    } catch (e) {
      _log.warning('gh pr create threw: $e');
      return PrCreationFailed(error: 'Failed to invoke gh CLI', details: e.toString());
    }
  }

  Future<bool> _ensureGhAvailable() async {
    if (_ghAvailable != null) return _ghAvailable!;

    try {
      final result = await _run('gh', ['--version']);
      _ghAvailable = result.exitCode == 0;
    } catch (_) {
      _ghAvailable = false;
    }

    return _ghAvailable!;
  }

  String _buildPrBody(Task task) {
    final parts = <String>[task.description];
    if (task.acceptanceCriteria != null) {
      parts.add('\n### Acceptance Criteria\n${task.acceptanceCriteria}');
    }
    parts.add('\n---\n_Created by DartClaw task ${task.id}_');
    return parts.join('\n');
  }

  String _manualPrInstructions(Project project, String branch) {
    return '''PR not created: gh CLI not found on PATH.
Branch "$branch" has been pushed to ${project.remoteUrl}.
To create a PR manually, run:
  gh pr create --head $branch --base ${project.defaultBranch}
Or visit: ${project.remoteUrl} and create a PR from the branch.''';
  }

  Future<ProcessResult> _run(String executable, List<String> arguments, {String? workingDirectory}) {
    final runner = _processRunner;
    if (runner != null) {
      return runner(executable, arguments, workingDirectory: workingDirectory);
    }
    return Process.run(executable, arguments, workingDirectory: workingDirectory);
  }
}
