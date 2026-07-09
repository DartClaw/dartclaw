part of 'cli_workflow_wiring.dart';

/// Transient internal state passed between [CliWorkflowWiring._wireXxx] methods.
///
/// Carries objects that exist only for the duration of [CliWorkflowWiring.wire]
/// and are not part of the public [CliWorkflowWiring] field surface.
final class _CliWorkflowWiringCtx {
  final WorkspaceSkillLinker workspaceSkillLinker;
  final TurnManager? turns;

  const _CliWorkflowWiringCtx({required this.workspaceSkillLinker, this.turns});

  TurnManager get turnsOrThrow => turns ?? (throw StateError('turns not yet bound'));

  _CliWorkflowWiringCtx withTurns(TurnManager turns) =>
      _CliWorkflowWiringCtx(workspaceSkillLinker: workspaceSkillLinker, turns: turns);
}

/// Intermediate repository and recorder handles produced by [CliWorkflowWiring._wireTaskLayer].
final class _TaskHandles {
  final SqliteAgentExecutionRepository agentExecutionRepository;
  final SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository;
  final SqliteExecutionRepositoryTransactor executionRepositoryTransactor;
  final SqliteTaskRepository taskRepository;
  final SqliteWorkflowRunRepository workflowRunRepository;
  final TaskEventRecorder taskEventRecorder;

  const _TaskHandles({
    required this.agentExecutionRepository,
    required this.workflowStepExecutionRepository,
    required this.executionRepositoryTransactor,
    required this.taskRepository,
    required this.workflowRunRepository,
    required this.taskEventRecorder,
  });
}

List<String> _gitArgsWithRemoteOverride(String originalRemoteUrl, String resolvedRemoteUrl, List<String> gitArgs) {
  if (originalRemoteUrl.trim().isEmpty || originalRemoteUrl == resolvedRemoteUrl) {
    return gitArgs;
  }
  return ['-c', 'remote.origin.url=$resolvedRemoteUrl', ...gitArgs];
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

int _standaloneTaskRunnerCapacity(DartclawConfig config) {
  if (config.providers.isEmpty) {
    return config.tasks.maxConcurrent > 0 ? config.tasks.maxConcurrent : 1;
  }
  return _effectiveWorkflowProviderEntries(config).values.fold<int>(0, (sum, entry) => sum + entry.effectivePoolSize);
}

Map<String, String> _providerEnvironment(DartclawConfig config, String providerId, CredentialRegistry registry) {
  final executable = _resolveProviderExecutable(config, providerId);
  return buildWorkflowProviderEnvironment(
    providerId: providerId,
    providerFamily: ProviderIdentity.resolveFamily(
      providerId,
      options: _providerOptions(config, providerId),
      executable: executable,
    ),
    registry: registry,
    baseEnvironment: Platform.environment,
  );
}

String _resolveProviderExecutable(DartclawConfig config, String providerId) {
  return resolveWorkflowProviderExecutable(config, providerId);
}

Map<String, dynamic> _providerOptions(DartclawConfig config, String providerId) =>
    workflowProviderOptions(config, providerId);

Future<String> _resolveWorkflowProjectDir(CliWorkflowWiring w, String? projectId) async {
  final trimmed = projectId?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == '_local') {
    return w.runtimeCwd;
  }
  final project = await w.projectService.get(trimmed);
  if (project == null) {
    throw StateError('Project "$trimmed" not found');
  }
  return project.localPath;
}

Future<WorkflowGitPublishResult> _publishWorkflowBranch(
  CliWorkflowWiring w, {
  required String projectId,
  required String branch,
}) async {
  final resolvedProject = await w.projectService.get(projectId);
  if (resolvedProject == null || resolvedProject.remoteUrl.isEmpty) {
    return publishWorkflowBranchLocally(projectDir: await _resolveWorkflowProjectDir(w, projectId), branch: branch);
  }
  return publishWorkflowBranchWithRemotePush(
    projectDir: resolvedProject.localPath,
    branch: branch,
    pushBranch: () => w.remotePushService.push(project: resolvedProject, branch: branch),
    fetchRemoteTrackingRef: () => _fetchRemoteTrackingRefWithProjectAuth(
      w,
      projectDir: resolvedProject.localPath,
      remoteUrl: resolvedProject.remoteUrl,
      credentialsRef: resolvedProject.credentialsRef,
      branch: branch,
      remote: 'origin',
    ),
  );
}

Future<ProcessResult> _fetchRemoteTrackingRefWithProjectAuth(
  CliWorkflowWiring w, {
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
    w.config.credentials,
    dataDir: w.dataDir,
    tempFiles: tempFiles,
  );
  try {
    final refspec = 'refs/heads/$branch:refs/remotes/$remote/$branch';
    final args = _gitArgsWithRemoteOverride(remoteUrl, plan.remoteUrl, ['fetch', '--no-tags', remote, refspec]);
    return SafeProcess.git(args, plan: plan, workingDirectory: projectDir, noSystemConfig: true);
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

Future<void> _cleanupWorkflowGitRun(
  CliWorkflowWiring w,
  String runId, {
  required String projectId,
  required String terminalStatus,
}) async {
  final run = await w.workflowService.get(runId);
  final runTasks = (await w.taskService.list()).where((task) => task.workflowRunId == runId).toList();
  final cleanupPlan = buildWorkflowCleanupPlan(runId, runTasks);
  final pushedBranches = w.config.workflow.cleanup.deleteRemoteBranchOnFailure && terminalStatus == 'failed'
      ? await _pushedWorkflowBranches(w, runTasks)
      : const <String>{};
  await _runWorkflowGitCleanupPlan(
    w,
    cleanupPlan,
    projectDir: await _resolveWorkflowProjectDir(w, projectId),
    remoteBranchesToDelete: pushedBranches,
    restoreRef: run?.variablesJson['BRANCH']?.trim(),
  );
}

Future<void> _cleanupTrackedWorkflowGit(CliWorkflowWiring w) async {
  final workflowTasks = (await w.taskService.list()).where((task) => task.workflowRunId != null).toList();
  if (workflowTasks.isEmpty) return;

  final runIds = workflowTasks.map((task) => task.workflowRunId).whereType<String>().toSet();
  for (final runId in runIds) {
    final run = await w.workflowService.get(runId);
    if (run != null && !run.status.terminal) {
      continue;
    }
    final restoreRef = run?.variablesJson['BRANCH']?.trim();
    final runTasks = workflowTasks.where((task) => task.workflowRunId == runId).toList();
    final projectIds = runTasks
        .map((task) => task.projectId?.trim())
        .where((id) => id != null && id.isNotEmpty && id != '_local')
        .toSet();
    final localTasks = runTasks.where((task) {
      final projectId = task.projectId?.trim();
      return projectId == null || projectId.isEmpty || projectId == '_local';
    }).toList();
    if (localTasks.isNotEmpty) {
      await _runWorkflowGitCleanupPlan(
        w,
        buildWorkflowCleanupPlan(runId, localTasks),
        projectDir: w.runtimeCwd,
        restoreRef: restoreRef,
      );
    }
    if (projectIds.isEmpty) {
      continue;
    }
    for (final projectId in projectIds) {
      await _runWorkflowGitCleanupPlan(
        w,
        buildWorkflowCleanupPlan(runId, runTasks.where((task) => task.projectId?.trim() == projectId).toList()),
        projectDir: await _resolveWorkflowProjectDir(w, projectId),
        restoreRef: restoreRef,
      );
    }
  }
}

Future<Set<String>> _pushedWorkflowBranches(CliWorkflowWiring w, List<Task> runTasks) async {
  final branches = <String>{};
  for (final task in runTasks) {
    final artifacts = await w.taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.kind == ArtifactKind.branch && artifact.path.trim().isNotEmpty) {
        branches.add(artifact.path.trim());
      }
    }
  }
  return branches;
}

Future<void> _runWorkflowGitCleanupPlan(
  CliWorkflowWiring w,
  WorkflowGitCleanupPlan cleanupPlan, {
  String? projectDir,
  Set<String> remoteBranchesToDelete = const {},
  String? restoreRef,
}) async {
  final cleanupLog = Logger('CliWorkflowWiring');
  final gitDir = projectDir ?? w.runtimeCwd;
  if (projectDir != null) {
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
  }
  for (final worktreePath in cleanupPlan.worktreePaths) {
    final result = await _runCleanupGit(
      ['worktree', 'remove', '--force', worktreePath],
      workingDirectory: gitDir,
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
      projectDir: gitDir,
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
      workingDirectory: gitDir,
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
