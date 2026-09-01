part of 'service_wiring.dart';

/// The repository a workflow run's git operations address.
///
/// A run that resolves a project addresses that project's checkout. A run that
/// resolves none — only possible in the zero-server lane, which tolerates an
/// absent or `_local` project id — addresses the repository the lane was
/// invoked in.
Future<String> _resolveWorkflowProjectDir(
  ProjectService projectService,
  String? projectId, {
  required String? localFallbackDir,
}) async {
  final trimmed = projectId?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == _localProjectId) {
    return localFallbackDir ?? (throw StateError('Workflow run resolved no project and this runtime has no local one'));
  }
  final project = await projectService.get(trimmed);
  if (project == null) {
    throw StateError('Project "$trimmed" not found');
  }
  return project.localPath;
}

const _localProjectId = '_local';

bool _isLocalProjectId(String? projectId) {
  final trimmed = projectId?.trim();
  return trimmed == null || trimmed.isEmpty || trimmed == _localProjectId;
}

Future<String?> _resolveSymbolicHeadBranch(String workingDirectory) async {
  try {
    final result = await runWorkflowGitCommand([
      'symbolic-ref',
      '--quiet',
      '--short',
      'HEAD',
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) return null;
    final stdout = (result.stdout as String).trim();
    return stdout.isEmpty ? null : stdout;
  } catch (_) {
    return null; // git not available or repo absent — caller treats null as unknown.
  }
}

List<String> _gitArgsWithRemoteOverride(String originalRemoteUrl, String resolvedRemoteUrl, List<String> gitArgs) {
  if (originalRemoteUrl.trim().isEmpty || originalRemoteUrl == resolvedRemoteUrl) {
    return gitArgs;
  }
  return ['-c', 'remote.origin.url=$resolvedRemoteUrl', ...gitArgs];
}

Future<ProcessResult> _fetchRemoteTrackingRefWithProjectAuth(
  DartclawConfig config, {
  required String dataDir,
  required String projectDir,
  required String remoteUrl,
  required String? credentialsRef,
  required String branch,
  required String remote,
}) async {
  final tempFiles = <String>[];
  final plan = resolveGitCredentialPlan(
    remoteUrl,
    credentialsRef,
    config.credentials,
    dataDir: dataDir,
    tempFiles: tempFiles,
  );
  try {
    final refspec = 'refs/heads/$branch:refs/remotes/$remote/$branch';
    final args = _gitArgsWithRemoteOverride(remoteUrl, plan.remoteUrl, ['fetch', '--no-tags', remote, refspec]);
    return await runGit(args, plan: plan, workingDirectory: projectDir);
  } finally {
    for (final path in tempFiles) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // Best-effort cleanup only; the files are scoped to DartClaw's data dir.
      }
    }
  }
}

/// Removes a finished run's worktrees and branches, restoring the checkout
/// before deleting a branch it is standing on.
///
/// Tolerant of a `ProcessException` throughout: teardown runs while the
/// operator may already have moved or removed the repository, and a cleanup
/// failure must not become the run's outcome.
Future<void> _runWorkflowGitCleanupPlan(
  WorkflowGitCleanupPlan cleanupPlan, {
  required String projectDir,
  Set<String> remoteBranchesToDelete = const {},
  String? restoreRef,
}) async {
  final cleanupLog = Logger('DartclawRuntime');
  for (final branch in remoteBranchesToDelete) {
    final result = await _runCleanupGit(
      ['push', 'origin', '--delete', branch],
      workingDirectory: projectDir,
      cleanupLog: cleanupLog,
      failureMessage: 'Remote workflow branch cleanup for "$branch"',
    );
    if (result == null) continue;
    final detail = result.exitCode == 0 ? 'succeeded' : 'failed: ${(result.stderr as String).trim()}';
    cleanupLog.info('Remote workflow branch cleanup for "$branch" $detail');
  }
  for (final worktreePath in cleanupPlan.worktreePaths) {
    final result = await _runCleanupGit(
      ['worktree', 'remove', '--force', worktreePath],
      workingDirectory: projectDir,
      cleanupLog: cleanupLog,
      failureMessage: 'Workflow worktree cleanup for "$worktreePath"',
    );
    if (result == null) continue;
    if (result.exitCode != 0) {
      cleanupLog.warning('Workflow worktree cleanup for "$worktreePath" failed: ${workflowGitFailureDetail(result)}');
    }
  }
  final localBranches = cleanupPlan.branches.where((branch) => !branch.startsWith('origin/')).toSet();
  if (localBranches.isNotEmpty) {
    final restoreError = await restoreCheckoutBeforeWorkflowBranchDeletion(
      projectDir: projectDir,
      workflowBranches: localBranches,
      restoreRef: restoreRef,
    );
    if (restoreError != null) {
      cleanupLog.warning(restoreError);
    }
  }
  for (final branch in localBranches) {
    final result = await _runCleanupGit(
      ['branch', '--delete', '--force', branch],
      workingDirectory: projectDir,
      cleanupLog: cleanupLog,
      failureMessage: 'Local workflow branch cleanup for "$branch"',
    );
    if (result == null) continue;
    if (result.exitCode != 0) {
      cleanupLog.warning('Local workflow branch cleanup for "$branch" failed: ${workflowGitFailureDetail(result)}');
    }
  }
}

Future<ProcessResult?> _runCleanupGit(
  List<String> args, {
  required String workingDirectory,
  required Logger cleanupLog,
  required String failureMessage,
}) async {
  try {
    return await runWorkflowGitCommand(args, workingDirectory: workingDirectory);
  } on ProcessException catch (error) {
    cleanupLog.warning('$failureMessage failed: ${error.message}');
    return null;
  }
}

/// Cleans up the workflow git state this process still tracks at teardown.
///
/// The zero-server lane owns the repository it was invoked in for the life of
/// the process, so a run that reached a terminal status must leave no workflow
/// worktree or branch behind, and the checkout must be restored before a branch
/// it is standing on is deleted. A run that is *not* terminal is left alone —
/// its worktrees and branches are what `workflow resume` picks back up.
Future<void> cleanupTrackedWorkflowGit({
  required TaskService taskService,
  required WorkflowService workflowService,
  required ProjectService projectService,
  required String localFallbackDir,
}) async {
  final workflowTasks = (await taskService.list()).where((task) => task.workflowRunId != null).toList();
  if (workflowTasks.isEmpty) return;

  final runIds = workflowTasks.map((task) => task.workflowRunId).whereType<String>().toSet();
  for (final runId in runIds) {
    final run = await workflowService.get(runId);
    if (run != null && !run.status.terminal) continue;
    final restoreRef = run?.variablesJson['BRANCH']?.trim();
    final runTasks = workflowTasks.where((task) => task.workflowRunId == runId).toList();
    final localTasks = runTasks.where((task) => _isLocalProjectId(task.projectId)).toList();
    if (localTasks.isNotEmpty) {
      await _runWorkflowGitCleanupPlan(
        buildWorkflowCleanupPlan(runId, localTasks),
        projectDir: localFallbackDir,
        restoreRef: restoreRef,
      );
    }
    final projectIds = runTasks
        .map((task) => task.projectId?.trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty && id != _localProjectId)
        .toSet();
    for (final projectId in projectIds) {
      await _runWorkflowGitCleanupPlan(
        buildWorkflowCleanupPlan(runId, runTasks.where((task) => task.projectId?.trim() == projectId).toList()),
        projectDir: await _resolveWorkflowProjectDir(projectService, projectId, localFallbackDir: localFallbackDir),
        restoreRef: restoreRef,
      );
    }
  }
}
