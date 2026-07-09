part of 'workflow_executor.dart';

extension WorkflowExecutorRunLifecycle on WorkflowExecutor {
  // ── Artifact commit ─────────────────────────────────────────────────────────

  Future<workflow_artifact_committer.ArtifactCommitResult> _maybeCommitArtifacts({
    required WorkflowRun run,
    required WorkflowDefinition definition,
    required WorkflowStep step,
    required WorkflowContext context,
    required Task task,
  }) => workflow_artifact_committer.maybeCommitStepArtifacts(
    workflow_artifact_committer.ArtifactCommitPolicy(
      run: run,
      definition: definition,
      step: step,
      context: context,
      task: task,
      projectService: _projectService,
      dataDir: _dataDir,
      templateEngine: _templateEngine,
      workflowGitPort: _workflowGitPort,
    ),
  );

  // ── Run persistence + initialization ────────────────────────────────────────

  Future<void> _persistContext(String runId, WorkflowContext context) =>
      persistWorkflowContext(dataDir: _dataDir, runId: runId, context: context);

  Future<String> _initializeRuntimeArtifactsDir(String runId) async {
    final dir = Directory(workflowRuntimeArtifactsDir(dataDir: _dataDir, runId: runId));
    await dir.create(recursive: true);
    // The engine owns and pre-creates only `reviews/` here (and `merge-resolve/`
    // via workflowMergeResolveAttemptsDir). Any other consumer must create its
    // own subdir; an absent custom subdir surfaces via MissingArtifactFailure.
    await Directory(p.join(dir.path, 'reviews')).create(recursive: true);
    return p.normalize(dir.path);
  }

  Future<String?> _initializeWorkflowGit(WorkflowRun run, WorkflowDefinition definition, WorkflowContext context) =>
      workflow_git_lifecycle.initializeWorkflowGit(
        run: run,
        definition: definition,
        context: context,
        turnAdapter: _turnAdapter,
        repository: _repository,
        persistContext: _persistContext,
        workflowProjectId: _workflowProjectId,
        requiresPerMapItemGitIsolation: (definition, context) =>
            step_config_policy.requiresPerMapItemGitIsolation(definition, context, templateEngine: _templateEngine),
      );

  String? _workflowProjectId(WorkflowRun run, WorkflowContext context) {
    final fromContext = context.variables['PROJECT']?.trim();
    if (fromContext != null && fromContext.isNotEmpty) return fromContext;
    final fromRun = run.variablesJson['PROJECT']?.trim();
    if (fromRun != null && fromRun.isNotEmpty) return fromRun;
    return null;
  }
}
