import 'package:dartclaw_core/dartclaw_core.dart' show Project;
import 'package:dartclaw_server/dartclaw_server.dart' show GitCredentialPlan;
import 'package:dartclaw_security/dartclaw_security.dart' show SafeProcess;
import 'package:logging/logging.dart';

final _log = Logger('WorkflowLocalPathPreflight');

Future<void> ensureWorkflowProjectReady({
  required Project project,
  required bool publishEnabled,
  required bool allowDirty,
  bool hasExplicitBranch = false,
}) async {
  if (project.id == '_local' || project.remoteUrl.isNotEmpty) {
    return;
  }

  await ensureWorkflowLocalPathProjectReady(
    projectId: project.id,
    localPath: project.localPath,
    configuredBranch: project.defaultBranch,
    publishEnabled: publishEnabled,
    allowDirty: allowDirty,
    hasExplicitBranch: hasExplicitBranch,
  );
}

Future<void> ensureWorkflowLocalPathProjectReady({
  required String projectId,
  required String localPath,
  required String configuredBranch,
  required bool publishEnabled,
  required bool allowDirty,
  bool hasExplicitBranch = false,
}) async {
  final status = await SafeProcess.git(
    const ['status', '--porcelain=v2', '--branch'],
    plan: const GitCredentialPlan.none(),
    workingDirectory: localPath,
    noSystemConfig: true,
  );
  if (status.exitCode != 0) {
    final stderr = (status.stderr as String).trim();
    throw StateError(
      'Failed to inspect local-path project "$projectId": ${stderr.isEmpty ? "git status failed" : stderr}',
    );
  }

  final parsed = _parseStatus(status.stdout as String);
  final branchMismatch = configuredBranch.isNotEmpty
      ? parsed.observedBranch != configuredBranch
      : (!hasExplicitBranch && parsed.observedBranch == '(detached)');
  final dirty = parsed.dirtyPathCount > 0;
  if (branchMismatch || dirty) {
    final branchExpectation = configuredBranch.isEmpty ? 'an attached branch' : '"$configuredBranch"';
    final message =
        'Local-path project "$projectId" is not safe to mutate: observed branch '
        '"${parsed.observedBranch}", expected $branchExpectation, dirty path count ${parsed.dirtyPathCount}.';
    if (!allowDirty) {
      throw StateError('$message Re-run with --allow-dirty-localpath to override.');
    }
    _log.warning('$message Proceeding because --allow-dirty-localpath was set.');
  }

  if (!publishEnabled) {
    return;
  }

  final origin = await SafeProcess.git(
    const ['remote', 'get-url', 'origin'],
    plan: const GitCredentialPlan.none(),
    workingDirectory: localPath,
    noSystemConfig: true,
  );
  if (origin.exitCode != 0) {
    final stderr = (origin.stderr as String).trim();
    throw StateError(
      'Publish requires an origin remote in local-path project "$projectId" '
      'working tree ($localPath).${stderr.isEmpty ? "" : " $stderr"}',
    );
  }
}

({String observedBranch, int dirtyPathCount}) _parseStatus(String stdout) {
  var observedBranch = '(detached)';
  var dirtyPathCount = 0;
  for (final rawLine in stdout.split('\n')) {
    final line = rawLine.trimRight();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith('# branch.head ')) {
      observedBranch = line.substring('# branch.head '.length).trim();
      continue;
    }
    if (line.startsWith('1 ') || line.startsWith('2 ') || line.startsWith('u ') || line.startsWith('? ')) {
      dirtyPathCount++;
    }
  }
  return (observedBranch: observedBranch, dirtyPathCount: dirtyPathCount);
}
