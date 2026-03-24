import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' show CredentialsConfig;
import 'package:dartclaw_models/dartclaw_models.dart' show Project;
import 'package:logging/logging.dart';

import 'git_credential_env.dart';

/// Result of a remote push attempt.
sealed class PushResult {
  const PushResult();
}

/// Branch was pushed successfully.
final class PushSuccess extends PushResult {
  const PushSuccess();
}

/// Push failed due to authentication or permission error.
final class PushAuthFailure extends PushResult {
  final String details;

  const PushAuthFailure(this.details);
}

/// Remote rejected the push (e.g. non-fast-forward).
final class PushRejected extends PushResult {
  final String reason;

  const PushRejected(this.reason);
}

/// Push failed for an unknown reason.
final class PushError extends PushResult {
  final String message;

  const PushError(this.message);
}

/// Pushes a branch to a project's remote via [Isolate.run].
///
/// Running git push in an Isolate prevents blocking the main event loop
/// on large branches or slow network connections.
class RemotePushService {
  static final _log = Logger('RemotePushService');

  final CredentialsConfig? _credentials;
  final String _dataDir;
  final List<String> _tempFiles = [];

  /// Injectable process runner for testing (bypasses Isolate).
  final Future<({int exitCode, String stdout, String stderr})> Function(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  })? _processRunner;

  RemotePushService({
    CredentialsConfig? credentials,
    String dataDir = '',
    Future<({int exitCode, String stdout, String stderr})> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    })? processRunner,
  })  : _credentials = credentials,
        _dataDir = dataDir,
        _processRunner = processRunner;

  /// Pushes [branch] to the remote for [project].
  ///
  /// Runs git push via [Isolate.run] to avoid blocking the event loop.
  /// Resolves credentials from [project.credentialsRef].
  Future<PushResult> push({
    required Project project,
    required String branch,
  }) async {
    final env = _credentials != null
        ? resolveGitCredentialEnv(
            project.remoteUrl,
            project.credentialsRef,
            _credentials,
            dataDir: _dataDir,
            tempFiles: _tempFiles,
          )
        : const <String, String>{};

    final localPath = project.localPath;
    final runner = _processRunner;

    late int exitCode;
    late String stderr;

    if (runner != null) {
      // Test path — use injectable runner directly.
      final result = await runner(
        'git',
        ['push', 'origin', branch],
        workingDirectory: localPath,
        environment: env.isEmpty ? null : env,
      );
      exitCode = result.exitCode;
      stderr = result.stderr;
    } else {
      // Production path — run in Isolate to avoid blocking event loop.
      final argsCopy = ['push', 'origin', branch];
      final envCopy = env.isEmpty ? null : Map<String, String>.unmodifiable(env);
      final wdCopy = localPath;

      final result = await Isolate.run(() async {
        final r = await Process.run(
          'git',
          argsCopy,
          workingDirectory: wdCopy,
          environment: envCopy,
        );
        return (
          exitCode: r.exitCode,
          stdout: r.stdout as String,
          stderr: r.stderr as String,
        );
      });
      exitCode = result.exitCode;
      stderr = result.stderr;
    }

    if (exitCode == 0) {
      _log.info('Pushed branch $branch for project ${project.id}');
      return const PushSuccess();
    }

    final stderrLower = stderr.toLowerCase();

    if (stderrLower.contains('permission denied') ||
        stderrLower.contains('authentication failed') ||
        stderrLower.contains('could not read username') ||
        stderrLower.contains('fatal: authentication')) {
      _log.warning('Push auth failure for branch $branch: $stderr');
      // Never include credential values in the result — only reference names.
      final credRef = project.credentialsRef;
      final credHint = credRef != null ? ' (credential: $credRef)' : '';
      return PushAuthFailure('Authentication denied$credHint. Check credentials configuration.');
    }

    if (stderrLower.contains('rejected') || stderrLower.contains('non-fast-forward')) {
      _log.warning('Push rejected for branch $branch: $stderr');
      return PushRejected(stderr.trim());
    }

    _log.warning('Push failed for branch $branch (exit $exitCode): $stderr');
    return PushError(stderr.trim().isNotEmpty ? stderr.trim() : 'git push exited with code $exitCode');
  }
}
