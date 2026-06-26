part of 'workflow_executor.dart';

/// Shared helper methods used by extracted workflow runners.
extension WorkflowExecutorHelpers on WorkflowExecutor {
  Map<String, OutputConfig> _inputConfigsFor(WorkflowDefinition definition, List<String> keys) {
    if (keys.isEmpty) return const {};
    final perDefinition = _inputConfigCache[definition] ??= <String, Map<String, OutputConfig>>{};
    final cacheKey = keys.join('\x00');
    return perDefinition.putIfAbsent(cacheKey, () => SkillPromptBuilder.collectInputConfigs(definition.steps, keys));
  }

  /// Resolved values for a step's inputs plus workflow variables used
  /// by auto-framing.
  ///
  /// Context inputs render missing entries as `''` so the auto-frame pass can
  /// drop an `_(empty)_` placeholder per the shared convention. Workflow
  /// variables only participate when they have a bound or default value –
  /// null-valued variables are intentionally omitted so they do not render as
  /// `_(empty)_`.
  Map<String, Object?> _resolvedInputValuesFor(
    WorkflowStep step,
    WorkflowDefinition definition,
    WorkflowContext context,
  ) {
    final values = <String, Object?>{for (final key in step.inputs) key: context[key] ?? ''};
    for (final entry in definition.variables.entries) {
      if (values.containsKey(entry.key)) continue;
      final resolved = context.variable(entry.key) ?? entry.value.defaultValue;
      if (resolved != null) values[entry.key] = resolved;
    }
    return values;
  }

  // Workflow-level `variables` are opt-in per step. Only names listed in
  // `step.workflowVariables` are auto-framed as `<NAME>{value}</NAME>` blocks
  // on that step's prompt. Undeclared variables never reach unrelated steps
  // (e.g. FEATURE must not land on unrelated steps). `inputs`
  // remains the declarative channel for upstream step outputs and is still
  // auto-framed by SkillPromptBuilder when `autoFrameContext` is true.
  List<String> _autoFrameVariableNames(WorkflowStep step) => step.workflowVariables;

  /// Returns an updated [WorkflowRun] when [step].entryGate evaluates false.
  ///
  /// Unlike [WorkflowStep.gate], entryGate does not pause the run on false; it
  /// is a clean skip. The skip outcome is written both to the in-memory
  /// [context] and to `run.contextJson` so later observers can distinguish a
  /// skipped step from "current step with no task yet".
  Future<WorkflowRun?> _skipDueToEntryGate(
    WorkflowRun run,
    WorkflowStep step,
    int stepIndex,
    WorkflowContext context,
  ) async {
    final expr = step.entryGate;
    if (expr == null || expr.trim().isEmpty) return null;
    final passes = _gateEvaluator.evaluate(expr, context);
    if (passes) return null;

    final now = DateTime.now();
    final outcomeKey = 'step.${step.id}.outcome';
    final reasonKey = 'step.${step.id}.outcome.reason';
    context[outcomeKey] = 'skipped';
    context[reasonKey] = expr;

    WorkflowExecutor._log.info("Workflow '${run.id}': step '${step.id}' skipped: entryGate='$expr' evaluated false");
    _eventBus.fire(StepSkippedEvent(runId: run.id, stepId: step.id, reason: expr, timestamp: now));

    final updated = run.copyWith(
      currentStepIndex: stepIndex + 1,
      contextJson: {...run.contextJson, outcomeKey: 'skipped', reasonKey: expr},
      updatedAt: now,
    );
    await _persistContext(run.id, context);
    await _repository.update(updated);
    return updated;
  }

  // ── Shared helpers ──────────────────────────────────────────────────────────

  Future<void> _createWorkflowTaskTriple({
    required String taskId,
    required WorkflowRun run,
    required WorkflowStep step,
    required int stepIndex,
    required String title,
    required String description,
    required TaskType type,
    required String? provider,
    required String? projectId,
    required int? maxTokens,
    required Map<String, dynamic> taskConfig,
  }) => workflow_task_factory.createWorkflowTaskTriple(
    ctx: StepExecutionContext(
      taskService: _taskService,
      eventBus: _eventBus,
      kvService: _kvService,
      repository: _repository,
      gateEvaluator: _gateEvaluator,
      contextExtractor: _contextExtractor,
      turnAdapter: _turnAdapter,
      outputTransformer: _outputTransformer,
      skillIntrospector: _skillIntrospector,
      skillPreflightConfig: _skillPreflightConfig,
      taskRepository: _taskRepository,
      agentExecutionRepository: _agentExecutionRepository,
      workflowStepExecutionRepository: _workflowStepExecutionRepository,
      executionTransactor: _executionTransactor,
      projectService: _projectService,
      defaultWorkspaceRoot: _defaultWorkspaceRoot,
      uuid: _uuid,
      workflowGitPort: _workflowGitPort,
    ),
    workflowWorkspaceDir: _resolveWorkflowWorkspaceDir(),
    taskId: taskId,
    run: run,
    step: step,
    stepIndex: stepIndex,
    title: title,
    description: description,
    type: type,
    provider: provider,
    projectId: projectId,
    maxTokens: maxTokens,
    taskConfig: taskConfig,
  );

  /// Builds configJson for a task from a workflow step and its resolved config.
  Map<String, dynamic> _buildStepConfig(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    ResolvedStepConfig resolved,
    WorkflowContext context, {
    required String resolvedWorktreeMode,
    required String effectivePromotion,
    Map<String, OutputConfig>? effectiveOutputs,
  }) => workflow_task_factory.buildStepConfig(
    run,
    definition,
    step,
    resolved,
    context,
    resolvedWorktreeMode: resolvedWorktreeMode,
    effectivePromotion: effectivePromotion,
    workflowWorkspaceDir: _resolveWorkflowWorkspaceDir(),
    effectiveOutputs: effectiveOutputs,
  );

  String _resolvedWorktreeModeForScope(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    int? enclosingMaxParallel,
    bool enclosingMapScope = false,
  }) => step_config_policy.resolveWorktreeModeForScope(
    definition,
    step,
    context,
    roleDefaults: _roleDefaults,
    enclosingMaxParallel: enclosingMaxParallel,
    enclosingMapScope: enclosingMapScope,
    templateEngine: _templateEngine,
  );

  String _effectivePromotion(WorkflowGitStrategy? strategy, {required String resolvedWorktreeMode}) =>
      step_config_policy.effectivePromotion(strategy, resolvedWorktreeMode: resolvedWorktreeMode);

  bool _stepNeedsWorktree(
    WorkflowDefinition definition,
    WorkflowStep step,
    ResolvedStepConfig resolved, {
    required String resolvedWorktreeMode,
    Map<String, OutputConfig>? effectiveOutputs,
  }) => step_config_policy.stepNeedsWorktree(
    definition,
    step,
    resolved,
    resolvedWorktreeMode: resolvedWorktreeMode,
    effectiveOutputs: effectiveOutputs,
  );

  bool _isLastBranchTouchingStepInScope(
    WorkflowDefinition definition,
    WorkflowStep step,
    Iterable<WorkflowStep> followingScopeSteps,
  ) {
    if (!_stepTouchesProjectBranch(definition, step)) return false;
    final currentRootId = _continueSessionRootStepId(definition, step);
    for (final candidate in followingScopeSteps) {
      if (!_stepTouchesProjectBranch(definition, candidate)) continue;
      if (_continueSessionRootStepId(definition, candidate) == currentRootId) {
        return false;
      }
    }
    return true;
  }

  bool _shouldBindWorkflowProject(
    WorkflowDefinition definition,
    WorkflowStep step,
    ResolvedStepConfig resolved, {
    Map<String, OutputConfig>? effectiveOutputs,
  }) => step_config_policy.shouldBindWorkflowProject(definition, step, resolved, effectiveOutputs: effectiveOutputs);

  bool _stepTouchesProjectBranch(WorkflowDefinition definition, WorkflowStep step) {
    return step_config_policy.stepTouchesProjectBranch(definition, step, roleDefaults: _roleDefaults);
  }

  String _continueSessionRootStepId(WorkflowDefinition definition, WorkflowStep step) =>
      _resolveContinueSessionRootStep(definition, step)?.id ?? step.id;

  /// Validates `story_specs` outputs emitted by the plan step.
  ///
  /// The primary side effect is path normalization against the emitted plan
  /// directory. When the step claims story-spec files that do not exist on
  /// disk, this returns a typed [StepValidationFailure] instead of mutating the
  /// output map with a reserved sentinel key.
  StorySpecOutputValidation _validateStorySpecOutputs(
    WorkflowRun run,
    WorkflowStep step,
    Map<String, dynamic> outputs,
    String? activeWorkspaceRoot,
  ) {
    final explicitPlanPath = (outputs['plan'] as String?)?.trim();
    final planPath = explicitPlanPath == null || explicitPlanPath.isEmpty ? null : explicitPlanPath;
    final planDir = (planPath == null || planPath.isEmpty) ? '' : p.dirname(planPath);

    final validation = step_outcome_normalizer.validateStorySpecOutputs(
      outputs,
      planDir: planDir,
      activeWorkspaceRoot: activeWorkspaceRoot,
    );
    final validationFailure = validation.validationFailure;
    if (validationFailure != null) {
      WorkflowExecutor._log.severe("Workflow '${run.id}': step '${step.id}': ${validationFailure.reason}");
    }
    return validation;
  }

  Future<String?> _resolveActiveWorkspaceRoot(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowContext context,
  ) async {
    final runWorktreePath = run.workflowWorktree?.path.trim();
    if (runWorktreePath != null && runWorktreePath.isNotEmpty) return runWorktreePath;

    final persistedWorktreePath = (await _repository.getWorktreeBinding(run.id))?.path.trim();
    if (persistedWorktreePath != null && persistedWorktreePath.isNotEmpty) return persistedWorktreePath;

    // _resolveWorkflowProjectTemplate yields null for an unset optional project
    // variable (standalone/inline), so an empty/absent project id falls through
    // to the default workspace root rather than failing the run.
    final projectId = _resolveWorkflowProjectTemplate(definition.project, context);
    if (projectId == null || projectId.isEmpty) return _normalizedDefaultWorkspaceRoot();

    final localPath = (await _projectService?.get(projectId))?.localPath.trim();
    if (localPath != null && localPath.isNotEmpty) return localPath;

    final dataDirProjectPath = p.join(_dataDir, 'projects', projectId);
    return Directory(dataDirProjectPath).existsSync() ? dataDirProjectPath : _normalizedDefaultWorkspaceRoot();
  }

  String? _normalizedDefaultWorkspaceRoot() {
    final root = _defaultWorkspaceRoot?.trim();
    if (root == null || root.isEmpty) return null;
    return p.normalize(p.absolute(root));
  }

  bool _emitsStorySpecs(WorkflowDefinition definition) =>
      definition.steps.any((step) => step.outputs?.containsKey('story_specs') ?? false);

  bool _isPromotionAwareScope(
    WorkflowGitStrategy? strategy, {
    required String resolvedWorktreeMode,
    required bool hasCodingSteps,
  }) => step_config_policy.isPromotionAwareScope(
    strategy,
    resolvedWorktreeMode: resolvedWorktreeMode,
    hasCodingSteps: hasCodingSteps,
  );

  bool _requiresPerMapItemBootstrap(WorkflowDefinition definition, WorkflowContext context) =>
      step_config_policy.requiresPerMapItemBootstrap(definition, context, templateEngine: _templateEngine);

  String? _mapItemSpecPath(MapContext mapCtx) {
    final item = mapCtx.item;
    final raw = switch (item) {
      final Map<String, dynamic> map => map['spec_path'],
      final Map<Object?, Object?> map => map['spec_path'],
      _ => null,
    };
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _mapItemDisplayScope(MapContext mapCtx) {
    final item = mapCtx.item;
    final raw = switch (item) {
      final Map<String, dynamic> map => map['id'],
      final Map<Object?, Object?> map => map['id'],
      _ => null,
    };
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Returns true if the workflow-level budget has been exceeded.
  ///
  /// [additionalTokens] is the evaluation-only foreach/loop-scope basis – see
  /// [workflow_budget_monitor.workflowBudgetExceeded].
  bool _workflowBudgetExceeded(WorkflowRun run, WorkflowDefinition definition, {int additionalTokens = 0}) =>
      workflow_budget_monitor.workflowBudgetExceeded(run, definition, additionalTokens: additionalTokens);

  /// Returns the workflow workspace directory used for task behavior injection.
  ///
  /// Custom workflow workspaces are supplied by the turn adapter. When no
  /// custom workspace is configured, materializes the built-in workflow
  /// workspace under `<dataDir>/workflow-workspace`.
  String _resolveWorkflowWorkspaceDir() {
    final cached = _workflowWorkspaceDirCache;
    if (cached != null) return cached;

    final defaultDir = p.join(_dataDir, 'workflow-workspace');
    final configuredDir = _turnAdapter?.workflowWorkspaceDir?.trim();
    final resolvedDir = (configuredDir == null || configuredDir.isEmpty) ? defaultDir : configuredDir;

    if (resolvedDir == defaultDir) {
      final dir = Directory(resolvedDir);
      final agentsPath = p.join(resolvedDir, 'AGENTS.md');
      dir.createSync(recursive: true);
      final file = File(agentsPath);
      if (!file.existsSync() || file.readAsStringSync() != builtInWorkflowAgentsMd) {
        file.writeAsStringSync(builtInWorkflowAgentsMd);
      }
    }

    _workflowWorkspaceDirCache = resolvedDir;
    return resolvedDir;
  }

  /// Fires a warning event when the workflow reaches 80% of its token budget.
  ///
  /// Deduplicated via `_budget.warningFired` in [run.contextJson] – fires once per run.
  /// Returns updated [run] if the flag was set, otherwise returns [run] unchanged.
  /// [additionalTokens] widens the comparison basis only; the persisted run keeps
  /// its real total.
  Future<WorkflowRun> _checkWorkflowBudgetWarning(
    WorkflowRun run,
    WorkflowDefinition definition, {
    int additionalTokens = 0,
  }) => workflow_budget_monitor.checkWorkflowBudgetWarning(
    run: run,
    definition: definition,
    eventBus: _eventBus,
    repository: _repository,
    additionalTokens: additionalTokens,
  );

  /// Reads the step's cumulative token count from session KV or task metadata.
  ///
  /// For [continueSession] steps, subtracts the baseline stored in
  /// [Task.configJson]['_sessionBaselineTokens'] so workflow totals only reflect
  /// new turns, not the full shared-session history.
  Future<int> _readStepTokenCount(Task task) => workflow_budget_monitor.readStepTokenCount(task, _kvService);

  /// Reads the raw cumulative token total for [sessionId] from KV store.
  Future<int> _readSessionTokens(String sessionId) => workflow_budget_monitor.readSessionTokens(_kvService, sessionId);

  void dispose() {
    approval_step_runner.cancelApprovalTimers(_approvalTimers);
  }
}
