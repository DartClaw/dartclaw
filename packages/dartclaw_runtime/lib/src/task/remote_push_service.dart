import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import '../project/project_auth_support.dart';
import 'git_credential_env.dart';
import 'host_worktree_git.dart';

/// Result of a remote push attempt.
sealed class PushResult {
  const new();
}

/// Branch was pushed successfully.
final class PushSuccess extends PushResult {
  const new();
}

/// Push failed due to authentication or permission error.
final class PushAuthFailure extends PushResult {
  final String details;

  const new(this.details);
}

/// Remote rejected the push (e.g. non-fast-forward).
final class PushRejected extends PushResult {
  final String reason;

  const new(this.reason);
}

/// Push failed for an unknown reason.
final class PushError extends PushResult {
  final String message;

  const new(this.message);
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

  /// Injectable git runner for testing (bypasses Isolate).
  final GitRunner? _processRunner;

  new({CredentialsConfig? credentials, String dataDir = '', GitRunner? processRunner})
    : _credentials = credentials,
      _dataDir = dataDir,
      _processRunner = processRunner;

  /// Removes temporary credential helper files created for git operations.
  void dispose() {
    for (final path in _tempFiles.toSet()) {
      try {
        File(path).deleteSync();
      } catch (e) {
        _log.fine('Failed to delete temp credential file $path: $e');
      }
    }
    _tempFiles.clear();
  }

  /// Resolves the single effective endpoint before an approval is recorded.
  Future<String> workflowPushDestination(Project project) async {
    final reference = project.credentialsRef;
    final entry = reference == null ? null : _credentials?[reference];
    final plannedUrl = gitHubRepositoryForToken(project.remoteUrl, entry)?.canonicalHttpsUrl ?? project.remoteUrl;
    final config = await _workflowPushConfig(project, plannedUrl);
    return _resolveWorkflowPushDestination(project, config);
  }

  Future<List<String>> _workflowPushConfig(Project project, String plannedUrl) async {
    if (plannedUrl == project.remoteUrl) return const [];
    final configured = await (_processRunner ?? runGit)(
      ['config', '--get-all', 'remote.origin.pushurl'],
      workingDirectory: project.localPath,
      noSystemConfig: false,
    );
    if (configured.exitCode == 0) return const [];
    if (configured.exitCode != 1) throw StateError('Failed to read the origin push URL configuration.');
    // An explicit push URL selects only the credential transport. A url
    // override would append another fetch and push URL to the remote.
    return ['-c', 'remote.origin.pushurl=$plannedUrl'];
  }

  Future<String> _resolveWorkflowPushDestination(Project project, List<String> config) async =>
      await resolveWorkflowPushDestination(
        workingDirectory: project.localPath,
        remote: 'origin',
        config: config,
        runner: _processRunner ?? runGit,
        noSystemConfig: false,
      ) ??
      (throw StateError('Origin has no workflow push URL.'));

  /// Pushes [branch] to the remote for [project].
  ///
  /// Runs git push via [Isolate.run] to avoid blocking the event loop.
  /// Resolves credentials from [project.credentialsRef].
  /// With [sourceRevision], pushes that full object ID to [branch] if the
  /// configured push endpoint still matches [expectedDestination].
  Future<PushResult> push({
    required Project project,
    required String branch,
    String? sourceRevision,
    String? expectedDestination,
  }) async {
    if (sourceRevision != null && !RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$').hasMatch(sourceRevision)) {
      return const PushError('Workflow push requires a full source revision.');
    }
    final credentials = _credentials;
    if (credentials != null) {
      final auth = describeProjectAuth(project, credentials);
      if (auth != null && !auth.compatible) {
        final credHint = project.credentialsRef != null ? ' (credential: ${project.credentialsRef})' : '';
        return PushAuthFailure('${auth.errorMessage}$credHint');
      }
    }

    final plan = credentials != null
        ? resolveGitCredentialPlan(
            project.remoteUrl,
            project.credentialsRef,
            credentials,
            dataDir: _dataDir,
            tempFiles: _tempFiles,
          )
        : GitCredentialPlan(remoteUrl: project.remoteUrl, environment: const <String, String>{});

    final localPath = project.localPath;
    final runner = _processRunner;
    final List<String> gitArgs;
    if (sourceRevision == null) {
      gitArgs = buildRemoteOverrideArgs(project.remoteUrl, plan.remoteUrl, ['push', 'origin', branch]);
    } else {
      try {
        final config = await _workflowPushConfig(project, plan.remoteUrl);
        final destination = await _resolveWorkflowPushDestination(project, config);
        if (destination != expectedDestination) return const PushError('Origin push URL changed after review.');
        gitArgs = [...config, ...pinnedBranchPushArguments(remote: 'origin', branch: branch, revision: sourceRevision)];
      } catch (error) {
        return const PushError('Failed to verify the reviewed origin push URL.');
      }
    }

    late int exitCode;
    late String stderr;

    if (runner != null) {
      // Test path — use injectable runner directly.
      final result = await runner(gitArgs, workingDirectory: localPath, plan: plan, noSystemConfig: false);
      exitCode = result.exitCode;
      stderr = result.stderr as String;
    } else {
      // Production path — run in Isolate to avoid blocking event loop.
      final envCopy = Map<String, String>.unmodifiable(plan.environment);
      final wdCopy = localPath;

      final result = await Isolate.run(() async {
        // Push is remote transport: it needs `insteadOf`, proxy and
        // `sshCommand` from user or system git config to work at all.
        final r = await runGit(
          gitArgs,
          plan: InlineProcessEnvironmentPlan(envCopy),
          workingDirectory: wdCopy,
          noSystemConfig: false,
        );
        return (exitCode: r.exitCode, stdout: r.stdout as String, stderr: r.stderr as String);
      });
      exitCode = result.exitCode;
      stderr = result.stderr;
    }

    if (exitCode == 0) {
      _log.info('Pushed branch $branch for project ${project.id}');
      return const PushSuccess();
    }

    if (sourceRevision != null) {
      if (expectedDestination != null) stderr = redactGitDestination(stderr, expectedDestination);
      stderr = redactGitDestination(redactGitDestination(stderr, plan.remoteUrl), project.remoteUrl);
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

String gitBranchName(String ref) {
  const prefix = 'refs/heads/';
  final normalized = normalizeGitRefOperand(ref, label: 'workflow branch');
  return normalized.startsWith(prefix) ? normalized.substring(prefix.length) : normalized;
}

List<String> pinnedBranchPushArguments({required String remote, required String branch, required String revision}) => [
  ...hostWorktreeGitOptions,
  'push',
  '--no-follow-tags',
  '--',
  remote,
  '$revision:refs/heads/${gitBranchName(branch)}',
];

Future<String?> resolveWorkflowPushDestination({
  required String workingDirectory,
  required String remote,
  List<String> config = const [],
  GitRunner runner = runGit,
  bool noSystemConfig = true,
}) async {
  final result = await runner(
    [...config, 'remote', 'get-url', '--all', '--push', remote],
    workingDirectory: workingDirectory,
    noSystemConfig: noSystemConfig,
  );
  if (result.exitCode == 2) return null;
  if (result.exitCode != 0) throw StateError('Failed to resolve the workflow push URL for "$remote".');
  final destinations = (result.stdout as String).trim().split('\n');
  if (destinations.length != 1 || destinations.single.isEmpty) {
    throw StateError('Workflow publish requires one push URL for "$remote".');
  }
  return destinations.single;
}

String redactGitDestination(String output, String destination) =>
    destination.isEmpty ? output : output.replaceAll(destination, '[remote]');
