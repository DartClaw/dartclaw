part of 'cli_workflow_wiring.dart';

WorkflowTurnAdapter _buildWorkflowTurnAdapter(CliWorkflowWiring w, _CliWorkflowWiringCtx ctx) {
  return WorkflowTurnAdapter(
    workflowWorkspaceDir: w.config.workflow.workspaceDir ?? p.join(w.dataDir, 'workflow-workspace'),
    resolveStartContext: (definition, variables, {projectId, allowDirtyLocalPath = false}) async {
      final declaresProject = definition.variables.containsKey('PROJECT');
      final declaresBranch = definition.variables.containsKey('BRANCH');
      final resolvedProjectId = (projectId ?? variables['PROJECT'])?.trim();
      final workflowProjectDir = await _resolveWorkflowProjectDir(w, resolvedProjectId);
      final resolvedProject = resolvedProjectId == null || resolvedProjectId.isEmpty
          ? null
          : await w.projectService.get(resolvedProjectId);
      String? resolvedBranch;
      if (declaresBranch) {
        final requested = variables['BRANCH']?.trim();
        if (requested != null && requested.isNotEmpty) {
          final safeRequested = normalizeGitRefOperand(requested, label: 'workflow BRANCH');
          final exists = await _localRefExists(workflowProjectDir, safeRequested);
          if (!exists) {
            throw ArgumentError('Ref "$safeRequested" not found in project repository');
          }
          resolvedBranch = safeRequested;
        } else if (resolvedProject != null) {
          resolvedBranch = await w.projectService.resolveWorkflowBaseRef(resolvedProject);
        } else {
          resolvedBranch = await _resolveSymbolicHeadBranch(workflowProjectDir) ?? 'main';
        }
      }
      if (resolvedProject != null) {
        await ensureWorkflowProjectReady(
          project: resolvedProject,
          publishEnabled: definition.gitStrategy?.publish?.enabled == true,
          allowDirty: allowDirtyLocalPath,
          hasExplicitBranch: (variables['BRANCH']?.trim().isNotEmpty ?? false),
        );
      }
      return WorkflowStartResolution(
        projectId: declaresProject ? resolvedProjectId : null,
        branch: declaresBranch ? resolvedBranch : null,
      );
    },
    initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
      final resolvedProject = await w.projectService.get(projectId);
      final effectiveBaseRef = resolvedProject != null
          ? await w.projectService.resolveWorkflowBaseRef(resolvedProject, requestedBranch: baseRef)
          : ((baseRef.trim().isNotEmpty)
                ? normalizeGitRefOperand(baseRef, label: 'workflow base ref')
                : (await _resolveSymbolicHeadBranch(await _resolveWorkflowProjectDir(w, projectId)) ?? 'main'));
      final integrationBranch = perMapItem
          ? 'dartclaw/workflow/${runId.replaceAll('-', '')}/integration'
          : 'dartclaw/workflow/${runId.replaceAll('-', '')}';
      await _ensureLocalBranch(
        projectDir: await _resolveWorkflowProjectDir(w, projectId),
        branch: integrationBranch,
        baseRef: effectiveBaseRef,
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
          return promoteWorkflowBranchLocally(
            projectDir: await _resolveWorkflowProjectDir(w, projectId),
            runId: runId,
            branch: branch,
            integrationBranch: integrationBranch,
            strategy: strategy,
            storyId: storyId,
          );
        },
    publishWorkflowBranch: ({required runId, required projectId, required branch}) async {
      final pushResult = await _publishWorkflowBranch(w, projectId: projectId, branch: branch);
      if (pushResult.status != WorkflowPublishStatus.success) {
        return pushResult;
      }

      // Optional PR-creation hook. Production CLI leaves prCreator null, so
      // publish.pr_url stays empty and the operator creates the PR manually.
      // When a hook is injected (tests / alternative entry points), its
      // result replaces the push-only outcome so the URL flows through
      // WorkflowGitPublishResult.prUrl into `publish.pr_url` context.
      var result = pushResult;
      if (w.prCreator != null) {
        final prResult = await w.prCreator!(runId: runId, projectId: projectId, branch: branch);
        result = WorkflowGitPublishResult(
          status: prResult.status,
          branch: pushResult.branch,
          remote: pushResult.remote,
          prUrl: prResult.prUrl,
          error: prResult.error,
        );
      }

      final workflowTasks = (await w.taskService.list()).where((task) => task.workflowRunId == runId).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final artifactTaskId = workflowTasks.isEmpty ? null : workflowTasks.last.id;
      if (artifactTaskId != null) {
        final artifactIdSuffix = DateTime.now().microsecondsSinceEpoch;
        await w.taskService.addArtifact(
          id: 'workflow-publish-$runId-branch-$artifactIdSuffix',
          taskId: artifactTaskId,
          name: 'Workflow Branch',
          kind: ArtifactKind.branch,
          path: branch,
        );
        if (result.prUrl.isNotEmpty) {
          await w.taskService.addArtifact(
            id: 'workflow-publish-$runId-pr-$artifactIdSuffix',
            taskId: artifactTaskId,
            name: 'Workflow Pull Request',
            kind: ArtifactKind.pr,
            path: result.prUrl,
          );
        }
      }
      return result;
    },
    cleanupWorkflowGit: ({required runId, required projectId, required status, required preserveWorktrees}) async {
      if (preserveWorktrees) return;
      await _cleanupWorkflowGitRun(w, runId, projectId: projectId, terminalStatus: status);
    },
    cleanupWorktreeForRetry: ({required projectId, required branch, required preAttemptSha}) async {
      final projectDir = await _resolveWorkflowProjectDir(w, projectId);
      return cleanupWorktreeForRetry(projectDir: projectDir, branch: branch, preAttemptSha: preAttemptSha);
    },
    captureWorkflowBranchSha: ({required projectId, required branch}) async {
      final projectDir = await _resolveWorkflowProjectDir(w, projectId);
      return captureWorkflowBranchSha(projectDir: projectDir, branch: branch);
    },
    captureAndCleanWorktreeForRetry: ({required projectId, required branch, preAttemptSha}) async {
      final projectDir = await _resolveWorkflowProjectDir(w, projectId);
      final result = await captureAndCleanWorktreeForRetry(
        projectDir: projectDir,
        branch: branch,
        preAttemptSha: preAttemptSha,
      );
      return (sha: result.sha, isDirty: result.isDirty, cleanupError: result.cleanupError);
    },
    runResolverAttemptUnderLock: <T>({required projectId, required body}) async {
      final projectDir = await _resolveWorkflowProjectDir(w, projectId);
      return runWorkflowGitResolverAttemptUnderLock<T>(projectDir: projectDir, body: body);
    },
    reserveTurn: ctx.turnsOrThrow.reserveTurn,
    reserveTurnWithWorkflowWorkspaceDir: (sessionId, workflowWorkspaceDir) => ctx.turnsOrThrow.reserveTurn(
      sessionId,
      agentName: 'task',
      behaviorOverride: BehaviorFileService(
        workspaceDir: workflowWorkspaceDir,
        maxMemoryBytes: w.config.memory.maxBytes,
        compactInstructions: w.config.context.compactInstructions,
        identifierPreservation: w.config.context.identifierPreservation,
        identifierInstructions: w.config.context.identifierInstructions,
      ),
      promptScope: PromptScope.task,
    ),
    executeTurn: ctx.turnsOrThrow.executeTurn,
    waitForOutcome: (sessionId, turnId) async {
      final outcome = await ctx.turnsOrThrow.waitForOutcome(sessionId, turnId);
      return WorkflowTurnOutcome(status: outcome.status.name);
    },
    availableRunnerCount: () => ctx.turnsOrThrow.availableRunnerCount,
  );
}
