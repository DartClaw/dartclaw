part of 'service_wiring.dart';

WorkflowTurnAdapter _buildWorkflowTurnAdapter(
  DartclawConfig config,
  _WiringContext ctx,
  StorageWiring storage,
  TaskWiring task,
  ProjectWiring project,
) {
  return WorkflowTurnAdapter(
    workflowWorkspaceDir: config.workflow.workspaceDir ?? p.join(ctx.dataDir, 'workflow-workspace'),
    resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
      final declaresProject = definition.variables.containsKey('PROJECT');
      final declaresBranch = definition.variables.containsKey('BRANCH');
      final projectService = project.projectService;

      var effectiveProjectId = (projectId ?? variables['PROJECT'])?.trim();
      Project resolvedProject;
      if (effectiveProjectId != null && effectiveProjectId.isNotEmpty) {
        final found = await projectService.get(effectiveProjectId);
        if (found == null) {
          throw ArgumentError('Project "$effectiveProjectId" not found');
        }
        resolvedProject = found;
      } else {
        resolvedProject = await projectService.defaultProject;
        if (declaresProject) {
          effectiveProjectId = resolvedProject.id;
        }
      }

      String? effectiveBranch;
      if (declaresBranch) {
        final requestedBranch = variables['BRANCH']?.trim();
        if (requestedBranch != null && requestedBranch.isNotEmpty) {
          final safeRequestedBranch = normalizeGitRefOperand(requestedBranch, label: 'workflow BRANCH');
          if (resolvedProject.remoteUrl.isEmpty) {
            final exists = await workflowLocalRefExists(resolvedProject.localPath, safeRequestedBranch);
            if (!exists) {
              throw ArgumentError('Ref "$safeRequestedBranch" not found in project repository');
            }
          }
          effectiveBranch = safeRequestedBranch;
        } else {
          effectiveBranch = await projectService.resolveWorkflowBaseRef(resolvedProject);
        }
      }

      await ensureWorkflowProjectReady(
        project: resolvedProject,
        publishEnabled: definition.gitStrategy?.publish == true,
        allowDirty: allowDirtyLocalPath,
        hasExplicitBranch: (variables['BRANCH']?.trim().isNotEmpty ?? false),
      );

      final refToValidate = _workflowFreshnessRefForProject(resolvedProject, effectiveBranch);
      await projectService.ensureFresh(resolvedProject, ref: refToValidate, strict: true);
      return WorkflowStartResolution(
        projectId: declaresProject ? effectiveProjectId : null,
        branch: declaresBranch ? effectiveBranch : null,
      );
    },
    initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
      final resolvedProject = await project.projectService.get(projectId);
      if (resolvedProject == null) {
        throw ArgumentError('Project "$projectId" not found');
      }
      final effectiveBaseRef = await project.projectService.resolveWorkflowBaseRef(
        resolvedProject,
        requestedBranch: baseRef,
      );
      final integrationBranch = resolveIntegrationBranchName(runId, perMapItem: perMapItem);
      await ensureWorkflowLocalBranch(
        projectDir: resolvedProject.localPath,
        branch: integrationBranch,
        baseRef: effectiveBaseRef,
        remoteBacked: resolvedProject.remoteUrl.isNotEmpty,
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
          final resolvedProject = await project.projectService.get(projectId);
          if (resolvedProject == null) {
            return WorkflowGitPromotionError('Project "$projectId" not found');
          }
          return promoteWorkflowBranchLocally(
            projectDir: resolvedProject.localPath,
            runId: runId,
            branch: branch,
            integrationBranch: integrationBranch,
            strategy: strategy,
            storyId: storyId,
          );
        },
    publishWorkflowBranch: ({required runId, required projectId, required branch}) async {
      final workflowRun = await storage.workflowRunRepository.getById(runId);
      return publishWorkflowBranchWithProjectAuth(
        runId: runId,
        projectId: projectId,
        branch: branch,
        projectService: project.projectService,
        taskService: storage.taskService,
        remotePushService: task.remotePushService,
        prCreator: task.prCreator,
        notes: workflowPublishNotes(workflowRun),
      );
    },
    cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
      if (preserveWorktrees) return;
      final resolvedProject = await project.projectService.get(projectId);
      if (resolvedProject == null) return;
      final workflowRun = await storage.workflowRunRepository.getById(runId);
      final restoreRef = workflowRun?.variablesJson['BRANCH']?.trim();
      final runTasks = (await storage.taskService.list())
          .where((candidate) => candidate.workflowRunId == runId)
          .toList();
      final cleanupPlan = buildWorkflowCleanupPlan(runId, runTasks);
      final gitDir = resolvedProject.localPath;
      final cleanupLog = Logger('ServiceWiring');

      if (config.workflow.cleanup.deleteRemoteBranchOnFailure && status == 'failed') {
        final pushedBranches = await pushedWorkflowBranches(storage.taskService, runTasks);
        for (final branch in pushedBranches) {
          final result = await runWorkflowGitCommand(['push', 'origin', '--delete', branch], workingDirectory: gitDir);
          final detail = result.exitCode == 0 ? 'succeeded' : 'failed: ${(result.stderr as String).trim()}';
          cleanupLog.info('Remote workflow branch cleanup for "$branch" $detail');
        }
      }

      for (final worktreePath in cleanupPlan.worktreePaths) {
        final result = await runWorkflowGitCommand([
          'worktree',
          'remove',
          '--force',
          worktreePath,
        ], workingDirectory: gitDir);
        if (result.exitCode != 0) {
          cleanupLog.warning(
            'Workflow worktree cleanup for "$worktreePath" failed: ${workflowGitFailureDetail(result)}',
          );
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
        final result = await runWorkflowGitCommand(['branch', '--delete', '--force', branch], workingDirectory: gitDir);
        if (result.exitCode != 0) {
          cleanupLog.warning('Local workflow branch cleanup for "$branch" failed: ${workflowGitFailureDetail(result)}');
        }
      }
    },
    cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async {
      final resolvedProject = await project.projectService.get(projectId);
      if (resolvedProject == null) return 'project "$projectId" not found';
      return cleanupWorktreeForRetry(
        projectDir: resolvedProject.localPath,
        branch: branch,
        preAttemptSha: preAttemptSha,
      );
    },
    captureWorkflowBranchSha: ({required projectId, required branch}) async {
      final resolvedProject = await project.projectService.get(projectId);
      if (resolvedProject == null) return null;
      return captureWorkflowBranchSha(projectDir: resolvedProject.localPath, branch: branch);
    },
    captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async {
      final resolvedProject = await project.projectService.get(projectId);
      if (resolvedProject == null) {
        return (sha: null, isDirty: false, cleanupError: 'project "$projectId" not found');
      }
      final result = await captureAndCleanWorktreeForRetry(
        projectDir: resolvedProject.localPath,
        branch: branch,
        preAttemptSha: preAttemptSha,
      );
      return (sha: result.sha, isDirty: result.isDirty, cleanupError: result.cleanupError);
    },
    runResolverAttemptUnderLock: <T>({required projectId, required body}) async {
      final resolvedProject = await project.projectService.get(projectId);
      if (resolvedProject == null) {
        throw ArgumentError('Project "$projectId" not found');
      }
      return runWorkflowGitResolverAttemptUnderLock<T>(projectDir: resolvedProject.localPath, body: body);
    },
    reserveTurn: ctx._serverTurns.reserveTurn,
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
      final runTasks = (await taskService.list()).where((candidate) => candidate.workflowRunId == runId).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final artifactTask = runTasks.isEmpty ? null : runTasks.last;
      await _persistWorkflowArtifact(
        taskService,
        runId,
        artifactTask?.id,
        'Workflow Branch',
        ArtifactKind.branch,
        branch,
      );
      if (resolvedProject.pr.strategy == PrStrategy.githubPr) {
        final syntheticTask =
            artifactTask ??
            Task(
              id: 'workflow-$runId',
              title: 'workflow($runId)',
              description: 'Workflow publish from $branch',
              type: TaskType.coding,
              createdAt: DateTime.now(),
            );
        final prResult = await prCreator.create(
          project: resolvedProject,
          task: syntheticTask,
          branch: branch,
          notes: notes,
        );
        switch (prResult) {
          case PrCreated(:final url):
            await _persistWorkflowArtifact(
              taskService,
              runId,
              artifactTask?.id,
              'Workflow Pull Request',
              ArtifactKind.pr,
              url,
            );
            return WorkflowGitPublishResult(
              status: WorkflowPublishStatus.success,
              branch: branch,
              remote: 'origin',
              prUrl: url,
            );
          case PrGhNotFound():
            return WorkflowGitPublishResult(
              status: WorkflowPublishStatus.manual,
              branch: branch,
              remote: 'origin',
              prUrl: '',
            );
          case PrCreationFailed(:final error, :final details):
            return WorkflowGitPublishResult(
              status: WorkflowPublishStatus.failed,
              branch: branch,
              remote: 'origin',
              prUrl: '',
              error: '$error: $details',
            );
        }
      }
      return WorkflowGitPublishResult(
        status: WorkflowPublishStatus.success,
        branch: branch,
        remote: 'origin',
        prUrl: '',
      );
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

Future<Set<String>> pushedWorkflowBranches(TaskService taskService, List<Task> runTasks) async {
  final branches = <String>{};
  for (final task in runTasks) {
    final artifacts = await taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.kind == ArtifactKind.branch && artifact.path.trim().isNotEmpty) {
        branches.add(artifact.path.trim());
      }
    }
  }
  return branches;
}

const _legacySessionCostFreshInputKey = 'new_input_tokens';
final _serviceWiringLog = Logger('ServiceWiring');

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
