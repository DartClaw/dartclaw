part of 'service_wiring.dart';

/// The provisioned DC-native inventory rides the probe result: execution
/// materializes it into project and worktree roots, so a provider CLI probe run
/// outside one never lists it.
SkillIntrospector _buildSkillIntrospector(
  _WiringContext ctx,
  Future<Map<String, String>> Function(String providerId) environmentForProvider,
) => CliSkillIntrospector(
  environmentForProvider: environmentForProvider,
  provisionedSkills: WorkspaceSkillInventory.fromDataDir(ctx.dataDir).skillNames.toSet(),
);

WorkflowTurnAdapter _buildWorkflowTurnAdapter(
  DartclawConfig config,
  _WiringContext ctx,
  StorageWiring storage,
  TaskWiring task,
  ProjectWiring project, {
  required String? localFallbackDir,
  required PrCreator? prCreator,
}) {
  final projectService = project.projectService;

  Future<String> projectDirFor(String? projectId) =>
      _resolveWorkflowProjectDir(projectService, projectId, localFallbackDir: localFallbackDir);

  /// The project a run addresses, or `null` when it addresses none.
  ///
  /// Answers only — the caller decides what an unresolvable id means, because
  /// the arms disagree: terminal cleanup skips it, promotion reports it, and
  /// the rest refuse. A `null` here means either "no project id" (only the
  /// zero-server lane, which falls back to its local repository) or "that id
  /// names no project".
  Future<Project?> resolveProject(String? projectId) async {
    final trimmed = projectId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return localFallbackDir != null ? null : await projectService.defaultProject;
    }
    if (localFallbackDir != null && trimmed == _localProjectId) return null;
    return projectService.get(trimmed);
  }

  /// The project [projectId] names, refusing rather than falling back — the
  /// shape every arm but terminal cleanup and promotion had before.
  Future<Project?> requireProject(String? projectId) async {
    final trimmed = projectId?.trim();
    final resolved = await resolveProject(projectId);
    if (resolved != null) return resolved;
    if (trimmed == null || trimmed.isEmpty || trimmed == _localProjectId) return null;
    throw ArgumentError('Project "$trimmed" not found');
  }

  return WorkflowTurnAdapter(
    workflowWorkspaceDir: config.workflow.workspaceDir ?? p.join(ctx.dataDir, 'workflow-workspace'),
    resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
      final declaresProject = definition.variables.containsKey('PROJECT');
      final declaresBranch = definition.variables.containsKey('BRANCH');

      var effectiveProjectId = (projectId ?? variables['PROJECT'])?.trim();
      final resolvedProject = await requireProject(effectiveProjectId);
      if (resolvedProject != null && (effectiveProjectId == null || effectiveProjectId.isEmpty) && declaresProject) {
        effectiveProjectId = resolvedProject.id;
      }

      String? effectiveBranch;
      if (declaresBranch) {
        final requestedBranch = variables['BRANCH']?.trim();
        if (requestedBranch != null && requestedBranch.isNotEmpty) {
          final safeRequestedBranch = normalizeGitRefOperand(requestedBranch, label: 'workflow BRANCH');
          // A remote-backed project can name a ref this checkout has not
          // fetched yet, so `serve` skips the lookup for one. The zero-server
          // lane never does: it operates on one checkout that is the whole
          // truth about its refs, and that lookup is part of its git safety.
          if (localFallbackDir != null || resolvedProject == null || resolvedProject.remoteUrl.isEmpty) {
            final searchDir = resolvedProject?.localPath ?? await projectDirFor(effectiveProjectId);
            final exists = await workflowLocalRefExists(searchDir, safeRequestedBranch);
            if (!exists) {
              throw ArgumentError('Ref "$safeRequestedBranch" not found in project repository');
            }
          }
          effectiveBranch = safeRequestedBranch;
        } else if (resolvedProject != null) {
          effectiveBranch = await projectService.resolveWorkflowBaseRef(resolvedProject);
        } else {
          effectiveBranch = await _resolveSymbolicHeadBranch(await projectDirFor(effectiveProjectId)) ?? 'main';
        }
      }

      // Both gates key off a resolved project: there is no project record to
      // check readiness or freshness against for a local-repository run.
      if (resolvedProject != null) {
        await ensureWorkflowProjectReady(
          project: resolvedProject,
          publishEnabled: definition.gitStrategy?.publish == true,
          allowDirty: allowDirtyLocalPath,
          hasExplicitBranch: (variables['BRANCH']?.trim().isNotEmpty ?? false),
        );
        final refToValidate = _workflowFreshnessRefForProject(resolvedProject, effectiveBranch);
        await projectService.ensureFresh(resolvedProject, ref: refToValidate, strict: true);
      }
      return WorkflowStartResolution(
        projectId: declaresProject ? effectiveProjectId : null,
        branch: declaresBranch ? effectiveBranch : null,
      );
    },
    initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
      final resolvedProject = await requireProject(projectId);
      final effectiveBaseRef = resolvedProject != null
          ? await projectService.resolveWorkflowBaseRef(resolvedProject, requestedBranch: baseRef)
          : (baseRef.trim().isNotEmpty
                ? normalizeGitRefOperand(baseRef, label: 'workflow base ref')
                : (await _resolveSymbolicHeadBranch(await projectDirFor(projectId)) ?? 'main'));
      final integrationBranch = resolveIntegrationBranchName(runId, perMapItem: perMapItem);
      await ensureWorkflowLocalBranch(
        projectDir: resolvedProject?.localPath ?? await projectDirFor(projectId),
        branch: integrationBranch,
        baseRef: effectiveBaseRef,
        remoteBacked: workflowBranchFollowsRemote(
          localFallbackDir: localFallbackDir,
          projectRemoteUrl: resolvedProject?.remoteUrl ?? '',
        ),
      );
      return WorkflowGitIntegrationBranchResult(integrationBranch: integrationBranch);
    },
    promoteWorkflowBranch:
        ({
          required runId,
          required projectId,
          required branch,
          required integrationBranch,
          required strategy,
          String? storyId,
        }) async {
          final resolvedProject = await requireProject(projectId);
          if (resolvedProject == null && !_isLocalProjectId(projectId)) {
            return WorkflowGitPromotionError('Project "$projectId" not found');
          }
          return promoteWorkflowBranchLocally(
            projectDir: resolvedProject?.localPath ?? await projectDirFor(projectId),
            runId: runId,
            branch: branch,
            integrationBranch: integrationBranch,
            strategy: strategy,
            storyId: storyId,
          );
        },
    publishWorkflowBranch: ({required runId, required projectId, required branch}) async {
      final workflowRun = await storage.workflowRunRepository.getById(runId);
      final resolvedProject = await resolveProject(projectId);
      // A zero-server run publishes what its own checkout can reach: locally
      // when there is no remote, otherwise a push against the project's
      // credentials. A connected run additionally opens the pull request the
      // project's strategy asks for.
      if (localFallbackDir != null) {
        return _publishWorkflowBranchLocalLane(
          config,
          dataDir: ctx.dataDir,
          localFallbackDir: localFallbackDir,
          taskService: storage.taskService,
          projectService: projectService,
          remotePushService: task.remotePushService,
          prCreator: prCreator,
          runId: runId,
          projectId: projectId,
          branch: branch,
          resolvedProject: resolvedProject,
          notes: workflowPublishNotes(workflowRun),
        );
      }
      return publishWorkflowBranchWithProjectAuth(
        runId: runId,
        projectId: projectId,
        branch: branch,
        projectService: projectService,
        taskService: storage.taskService,
        remotePushService: task.remotePushService,
        prCreator: prCreator ?? task.prCreator,
        notes: workflowPublishNotes(workflowRun),
      );
    },
    cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
      if (preserveWorktrees) return;
      final resolvedProject = await resolveProject(projectId);
      if (resolvedProject == null && !_isLocalProjectId(projectId)) return;
      final workflowRun = await storage.workflowRunRepository.getById(runId);
      final runTasks = (await storage.taskService.list())
          .where((candidate) => candidate.workflowRunId == runId)
          .toList();
      final deleteRemote = config.workflow.cleanup.deleteRemoteBranchOnFailure && status == 'failed';
      await _runWorkflowGitCleanupPlan(
        buildWorkflowCleanupPlan(runId, runTasks),
        projectDir: resolvedProject?.localPath ?? await projectDirFor(projectId),
        remoteBranchesToDelete: deleteRemote
            ? await workflowPushedBranches(storage.taskService, runTasks)
            : const <String>{},
        restoreRef: workflowRun?.variablesJson['BRANCH']?.trim(),
      );
    },
    cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async {
      final projectDir = await _projectDirOrNull(projectService, projectId, localFallbackDir);
      if (projectDir == null) return 'project "$projectId" not found';
      return cleanupWorktreeForRetry(projectDir: projectDir, branch: branch, preAttemptSha: preAttemptSha);
    },
    captureWorkflowBranchSha: ({required projectId, required branch}) async {
      final projectDir = await _projectDirOrNull(projectService, projectId, localFallbackDir);
      if (projectDir == null) return null;
      return captureWorkflowBranchSha(projectDir: projectDir, branch: branch);
    },
    captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async {
      final projectDir = await _projectDirOrNull(projectService, projectId, localFallbackDir);
      if (projectDir == null) {
        return (sha: null, isDirty: false, cleanupError: 'project "$projectId" not found');
      }
      final result = await captureAndCleanWorktreeForRetry(
        projectDir: projectDir,
        branch: branch,
        preAttemptSha: preAttemptSha,
      );
      return (sha: result.sha, isDirty: result.isDirty, cleanupError: result.cleanupError);
    },
    runResolverAttemptUnderLock: <T>({required projectId, required body}) async {
      final projectDir = await _projectDirOrNull(projectService, projectId, localFallbackDir);
      if (projectDir == null) {
        throw ArgumentError('Project "$projectId" not found');
      }
      return runWorkflowGitResolverAttemptUnderLock<T>(projectDir: projectDir, body: body);
    },
    reserveTurn: (sessionId) => ctx._serverTurns.reserveTurn(sessionId, promptScope: PromptScope.task),
    reserveTurnWithWorkflowWorkspaceDir: (sessionId, workflowWorkspaceDir) => ctx._serverTurns.reserveTurn(
      sessionId,
      agentName: 'task',
      behaviorOverride: BehaviorFileService(
        workspaceDir: workflowWorkspaceDir,
        maxMemoryBytes: config.memory.maxBytes,
        onboardingExpiryDays: config.onboarding.expiryDays,
        compactInstructions: config.context.compactInstructions,
        identifierPreservation: config.context.identifierPreservation,
        identifierInstructions: config.context.identifierInstructions,
      ),
      promptScope: PromptScope.task,
    ),
    executeTurn: ctx._serverTurns.executeTurn,
    waitForOutcome: (sessionId, turnId) async {
      final outcome = await ctx._serverTurns.waitForOutcome(sessionId, turnId);
      return WorkflowTurnOutcome(status: outcome.status.name);
    },
    availableRunnerCount: () => ctx._serverTurns.availableRunnerCount,
  );
}

/// The checkout a retry/lock helper addresses, or `null` when the named project
/// does not exist and there is no local repository to stand in for it.
Future<String?> _projectDirOrNull(ProjectService projectService, String projectId, String? localFallbackDir) async {
  if (_isLocalProjectId(projectId)) return localFallbackDir;
  final resolved = await projectService.get(projectId);
  if (resolved != null) return resolved.localPath;
  // A lane with a local repository still refuses a *named* project it cannot
  // find; falling back there would run the retry against the wrong checkout.
  if (localFallbackDir != null) throw StateError('Project "$projectId" not found');
  return null;
}

/// The zero-server publish: local when the run addresses no remote-backed
/// project, otherwise a push against that project's credentials with a
/// remote-tracking refresh. Only the push arm can open a pull request, and only
/// when a creator was supplied — production leaves it to the operator, and a
/// local publish has no project record to open one against.
Future<WorkflowGitPublishResult> _publishWorkflowBranchLocalLane(
  DartclawConfig config, {
  required String dataDir,
  required String localFallbackDir,
  required TaskService taskService,
  required ProjectService projectService,
  required RemotePushService remotePushService,
  required PrCreator? prCreator,
  required String runId,
  required String projectId,
  required String branch,
  required Project? resolvedProject,
  required String? notes,
}) async {
  if (resolvedProject == null || resolvedProject.remoteUrl.isEmpty) {
    final projectDir =
        resolvedProject?.localPath ??
        await _resolveWorkflowProjectDir(projectService, projectId, localFallbackDir: localFallbackDir);
    final result = await publishWorkflowBranchLocally(projectDir: projectDir, branch: branch);
    if (result.status != WorkflowPublishStatus.success) return result;
    await _recordWorkflowPublishArtifacts(taskService, runId: runId, branch: branch, result: result);
    return result;
  }
  final pushResult = await publishWorkflowBranchWithRemotePush(
    projectDir: resolvedProject.localPath,
    branch: branch,
    pushBranch: () => remotePushService.push(project: resolvedProject, branch: branch),
    fetchRemoteTrackingRef: () => _fetchRemoteTrackingRefWithProjectAuth(
      config,
      dataDir: dataDir,
      projectDir: resolvedProject.localPath,
      remoteUrl: resolvedProject.remoteUrl,
      credentialsRef: resolvedProject.credentialsRef,
      branch: branch,
      remote: 'origin',
    ),
  );
  if (pushResult.status != WorkflowPublishStatus.success) {
    return pushResult;
  }
  var result = pushResult;
  if (prCreator != null) {
    final artifactTask = await _latestWorkflowTask(taskService, runId);
    final prResult = await prCreator.create(
      project: resolvedProject,
      task:
          artifactTask ??
          Task(
            id: 'workflow-$runId',
            title: 'workflow($runId)',
            description: 'Workflow publish from $branch',
            createdAt: DateTime.now(),
          ),
      branch: branch,
      notes: notes,
    );
    result = switch (prResult) {
      PrCreated(:final url) => WorkflowGitPublishResult(
        status: WorkflowPublishStatus.success,
        branch: pushResult.branch,
        remote: pushResult.remote,
        prUrl: url,
      ),
      PrGhNotFound() => WorkflowGitPublishResult(
        status: WorkflowPublishStatus.manual,
        branch: pushResult.branch,
        remote: pushResult.remote,
        prUrl: '',
      ),
      PrCreationFailed(:final error, :final details) => WorkflowGitPublishResult(
        status: WorkflowPublishStatus.failed,
        branch: pushResult.branch,
        remote: pushResult.remote,
        prUrl: '',
        error: '$error: $details',
      ),
    };
  }
  await _recordWorkflowPublishArtifacts(taskService, runId: runId, branch: branch, result: result);
  return result;
}

Future<Task?> _latestWorkflowTask(TaskService taskService, String runId) async {
  final runTasks = (await taskService.list()).where((candidate) => candidate.workflowRunId == runId).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return runTasks.isEmpty ? null : runTasks.last;
}

/// Records the branch (and pull request, when one exists) as artifacts of the
/// run's last task — the one implementation both publish arms use.
Future<void> _recordWorkflowPublishArtifacts(
  TaskService taskService, {
  required String runId,
  required String branch,
  required WorkflowGitPublishResult result,
}) async {
  final artifactTask = await _latestWorkflowTask(taskService, runId);
  if (artifactTask == null) return;
  await _persistWorkflowArtifact(taskService, runId, artifactTask.id, 'Workflow Branch', ArtifactKind.branch, branch);
  if (result.prUrl.isNotEmpty) {
    await _persistWorkflowArtifact(
      taskService,
      runId,
      artifactTask.id,
      'Workflow Pull Request',
      ArtifactKind.pr,
      result.prUrl,
    );
  }
}

String? _workflowFreshnessRefForProject(Project project, String? branch) {
  if (branch == null || branch.isEmpty) return null;
  if (project.remoteUrl.isNotEmpty && branch.startsWith('origin/')) {
    final trimmed = branch.substring('origin/'.length).trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return branch;
}

Future<void> _persistWorkflowArtifact(
  TaskService taskService,
  String runId,
  String? taskId,
  String name,
  ArtifactKind kind,
  String content,
) async {
  if (taskId == null || taskId.isEmpty) return;
  await taskService.addArtifact(
    id: 'workflow-publish-$runId-${kind.name}-${DateTime.now().microsecondsSinceEpoch}',
    taskId: taskId,
    name: name,
    kind: kind,
    path: content,
  );
}

/// Derives the PR-body notes for a workflow publish: the run's blocked-outcome
/// summary, scrubbed line-by-line. The scrub is defense-in-depth at this
/// boundary – the summary embeds context reason strings and the PR body is an
/// off-machine sink (alongside the engine-side sanitization and PrCreator's
/// code-block framing). Null when the run row is missing or nothing blocked.
String? workflowPublishNotes(WorkflowRun? run) {
  if (run == null) return null;
  return workflowBlockedOutcomeSummary(run)?.split('\n').map(scrubAgentReportedText).join('\n');
}

Future<WorkflowGitPublishResult> publishWorkflowBranchWithProjectAuth({
  required String runId,
  required String projectId,
  required String branch,
  required ProjectService projectService,
  required TaskService taskService,
  required RemotePushService remotePushService,
  required PrCreator prCreator,
  String? notes,
}) async {
  final resolvedProject = await projectService.get(projectId);
  if (resolvedProject == null) {
    return WorkflowGitPublishResult(
      status: WorkflowPublishStatus.failed,
      branch: branch,
      remote: 'origin',
      prUrl: '',
      error: 'Project "$projectId" not found',
    );
  }

  try {
    await commitWorkflowWorktreeChangesIfNeeded(
      projectDir: resolvedProject.localPath,
      branch: branch,
      commitMessage: 'workflow: prepare publish',
    );
  } catch (e) {
    return WorkflowGitPublishResult(
      status: WorkflowPublishStatus.failed,
      branch: branch,
      remote: 'origin',
      prUrl: '',
      error: 'Failed to commit pending worktree changes before publish: $e',
    );
  }

  final pushResult = await remotePushService.push(project: resolvedProject, branch: branch);
  switch (pushResult) {
    case PushSuccess():
      final artifactTask = await _latestWorkflowTask(taskService, runId);
      var result = WorkflowGitPublishResult(
        status: WorkflowPublishStatus.success,
        branch: branch,
        remote: 'origin',
        prUrl: '',
      );
      if (resolvedProject.pr.strategy == PrStrategy.githubPr) {
        final syntheticTask =
            artifactTask ??
            Task(
              id: 'workflow-$runId',
              title: 'workflow($runId)',
              description: 'Workflow publish from $branch',
              createdAt: DateTime.now(),
            );
        final prResult = await prCreator.create(
          project: resolvedProject,
          task: syntheticTask,
          branch: branch,
          notes: notes,
        );
        result = switch (prResult) {
          PrCreated(:final url) => WorkflowGitPublishResult(
            status: WorkflowPublishStatus.success,
            branch: branch,
            remote: 'origin',
            prUrl: url,
          ),
          PrGhNotFound() => WorkflowGitPublishResult(
            status: WorkflowPublishStatus.manual,
            branch: branch,
            remote: 'origin',
            prUrl: '',
          ),
          PrCreationFailed(:final error, :final details) => WorkflowGitPublishResult(
            status: WorkflowPublishStatus.failed,
            branch: branch,
            remote: 'origin',
            prUrl: '',
            error: '$error: $details',
          ),
        };
      }
      // The push landed, so the branch is an artifact whatever the pull request
      // did. One writer for both arms: two would drift on exactly that rule.
      await _recordWorkflowPublishArtifacts(taskService, runId: runId, branch: branch, result: result);
      return result;
    case PushAuthFailure(:final details):
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.failed,
        branch: branch,
        remote: 'origin',
        prUrl: '',
        error: 'Authentication failed: $details',
      );
    case PushRejected(:final reason):
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.failed,
        branch: branch,
        remote: 'origin',
        prUrl: '',
        error: 'Remote rejected push: $reason',
      );
    case PushError(:final message):
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.failed,
        branch: branch,
        remote: 'origin',
        prUrl: '',
        error: message,
      );
  }
}

const _legacySessionCostFreshInputKey = 'new_input_tokens';
final _serviceWiringLog = Logger('DartclawRuntime');

Future<void> _dropLegacySessionCostEntries(KvService kvService) async {
  final entries = await kvService.getByPrefix('session_cost:');
  var dropped = 0;
  for (final entry in entries.entries) {
    try {
      final decoded = jsonDecode(entry.value);
      if (decoded is Map<String, dynamic> && decoded.containsKey(_legacySessionCostFreshInputKey)) {
        await kvService.delete(entry.key);
        dropped++;
      }
    } catch (_) {
      continue; // Malformed or deleted key — skip silently; migration is best-effort.
    }
  }
  _serviceWiringLog.info('Dropped $dropped legacy session_cost entries (pre-Tier-1b schema)');
}
