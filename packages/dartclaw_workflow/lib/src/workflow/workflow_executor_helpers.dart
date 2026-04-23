part of 'workflow_executor.dart';

/// Shared helper methods used by extracted workflow runners.
extension WorkflowExecutorHelpers on WorkflowExecutor {
  Map<String, OutputConfig> _inputConfigsFor(WorkflowDefinition definition, List<String> keys) {
    if (keys.isEmpty) return const {};
    final perDefinition = _inputConfigCache[definition] ??= <String, Map<String, OutputConfig>>{};
    final cacheKey = keys.join('\x00');
    return perDefinition.putIfAbsent(cacheKey, () => SkillPromptBuilder.collectInputConfigs(definition.steps, keys));
  }

  /// Returns the `workflow.default_prompt` declared in the step's skill
  /// frontmatter, or null when no registry is wired, the step has no skill,
  /// or the skill declares no default.
  String? _skillDefaultPromptFor(WorkflowStep step) {
    final skill = step.skill;
    if (skill == null) return null;
    return _skillRegistry?.getByName(skill)?.defaultPrompt;
  }

  /// Returns the effective `outputs:` for a step, shallow-merging the skill's
  /// `workflow.default_outputs` (keys only in the skill default are added;
  /// keys on the step win).
  Map<String, OutputConfig>? _effectiveOutputsFor(WorkflowStep step) {
    final explicit = step.outputs;
    final skill = step.skill;
    if (skill == null || _skillRegistry == null) return explicit;
    final defaults = _skillRegistry.getByName(skill)?.defaultOutputs;
    if (defaults == null || defaults.isEmpty) return explicit;
    if (explicit == null || explicit.isEmpty) return defaults;
    return {...defaults, ...explicit};
  }

  /// Resolved values for a step's contextInputs plus workflow variables used
  /// by auto-framing.
  ///
  /// Context inputs render missing entries as `''` so the auto-frame pass can
  /// drop an `_(empty)_` placeholder per the shared convention. Workflow
  /// variables only participate when they have a bound or default value —
  /// null-valued variables are intentionally omitted so they do not render as
  /// `_(empty)_`.
  Map<String, Object?> _resolvedInputValuesFor(
    WorkflowStep step,
    WorkflowDefinition definition,
    WorkflowContext context,
  ) {
    final values = <String, Object?>{for (final key in step.contextInputs) key: context[key] ?? ''};
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
  // (e.g. REQUIREMENTS must not land on discover-project). `contextInputs`
  // remains the declarative channel for upstream step outputs and is still
  // auto-framed by SkillPromptBuilder when `autoFrameContext` is true.
  List<String> _autoFrameVariableNames(WorkflowStep step) => step.workflowVariables;

  Future<void> _maybeCommitArtifacts({
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
    ),
  );

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

  // ── Parallel group helpers ──────────────────────────────────────────────────

  int _nodeIndexForStepIndex(List<WorkflowNode> nodes, Map<String, int> stepIndexById, int stepIndex) {
    if (nodes.isEmpty) return 0;
    for (var index = 0; index < nodes.length; index++) {
      final referencedIndexes = _referencedStepIdsForNode(
        nodes[index],
      ).map((stepId) => stepIndexById[stepId]).nonNulls.toList(growable: false);
      if (referencedIndexes.contains(stepIndex)) {
        return index;
      }
      final firstStepIndex = referencedIndexes.isEmpty
          ? 0
          : referencedIndexes.reduce((left, right) => left < right ? left : right);
      if (firstStepIndex >= stepIndex) {
        return index;
      }
    }
    return nodes.length;
  }

  int _nodeIndexForCursor(List<WorkflowNode> nodes, Map<String, int> stepIndexById, WorkflowExecutionCursor cursor) =>
      _nodeIndexForStepIndex(nodes, stepIndexById, cursor.stepIndex);

  WorkflowExecutionCursor? _legacyResumeCursor(
    WorkflowDefinition definition, {
    int? startFromLoopIndex,
    int? startFromLoopIteration,
    String? startFromLoopStepId,
  }) {
    if (startFromLoopIndex == null || startFromLoopIndex < 0 || startFromLoopIndex >= definition.loops.length) {
      return null;
    }
    final loop = definition.loops[startFromLoopIndex];
    final firstStepId = startFromLoopStepId ?? loop.steps.firstOrNull;
    final stepIndex = firstStepId == null ? 0 : definition.steps.indexWhere((step) => step.id == firstStepId);
    return WorkflowExecutionCursor.loop(
      loopId: loop.id,
      stepIndex: stepIndex >= 0 ? stepIndex : 0,
      iteration: startFromLoopIteration ?? 1,
      stepId: startFromLoopStepId,
    );
  }

  int _firstStepIndexForNode(WorkflowNode node, Map<String, int> stepIndexById) {
    final indexes = _referencedStepIdsForNode(
      node,
    ).map((stepId) => stepIndexById[stepId]).nonNulls.toList(growable: false);
    if (indexes.isEmpty) return 0;
    return indexes.reduce((left, right) => left < right ? left : right);
  }

  Iterable<String> _referencedStepIdsForNode(WorkflowNode node) sync* {
    switch (node) {
      case ActionNode(stepId: final stepId):
        yield stepId;
      case MapNode(stepId: final stepId):
        yield stepId;
      case ParallelGroupNode(stepIds: final stepIds):
        yield* stepIds;
      case LoopNode(stepIds: final stepIds, finallyStepId: final finallyStepId):
        yield* stepIds;
        if (finallyStepId != null) {
          yield finallyStepId;
        }
      case ForeachNode(stepId: final stepId, childStepIds: final childStepIds):
        yield stepId;
        yield* childStepIds;
    }
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
    required int maxRetries,
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
      skillRegistry: _skillRegistry,
      taskRepository: _taskRepository,
      agentExecutionRepository: _agentExecutionRepository,
      workflowStepExecutionRepository: _workflowStepExecutionRepository,
      executionTransactor: _executionTransactor,
      projectService: _projectService,
      uuid: _uuid,
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
    maxRetries: maxRetries,
    taskConfig: taskConfig,
  );

  /// Waits for a task to complete using a pre-created [completer] and [sub].
  Future<Task> _waitForTaskCompletion(
    String taskId,
    WorkflowStep step,
    Completer<Task> completer,
    StreamSubscription<TaskStatusChangedEvent> sub, {
    String? runId,
  }) async {
    // Wake the wait if the owning workflow run transitions away from `running`
    // (e.g. `WorkflowService.pause(runId)` → `WorkflowRunStatusChangedEvent`).
    // Without this, a step blocked on a task that never completes would hold
    // the executor indefinitely, and pause/cancel would observe no effect.
    StreamSubscription<WorkflowRunStatusChangedEvent>? runSub;
    if (runId != null) {
      runSub = _eventBus.on<WorkflowRunStatusChangedEvent>().where((e) => e.runId == runId).listen((event) {
        if (event.newStatus != WorkflowRunStatus.running && !completer.isCompleted) {
          completer.completeError(
            StateError(
              'Workflow run "$runId" transitioned to ${event.newStatus.name} while step "${step.name}" awaited task $taskId',
            ),
          );
        }
      });
      // Close the race: if pause fired before we subscribed, the broadcast
      // stream dropped the event. Re-check current state from the repository
      // and abort if the run is no longer running.
      final currentRun = await _repository.getById(runId);
      if (currentRun != null && currentRun.status != WorkflowRunStatus.running && !completer.isCompleted) {
        completer.completeError(
          StateError(
            'Workflow run "$runId" is ${currentRun.status.name}; step "${step.name}" wait aborted before task $taskId completed',
          ),
        );
      }
    }
    try {
      if (step.timeoutSeconds != null) {
        return await completer.future.timeout(
          Duration(seconds: step.timeoutSeconds!),
          onTimeout: () =>
              throw TimeoutException('Step "${step.name}" timed out', Duration(seconds: step.timeoutSeconds!)),
        );
      } else {
        return await completer.future;
      }
    } finally {
      await sub.cancel();
      await runSub?.cancel();
    }
  }

  /// Builds configJson for a task from a workflow step and its resolved config.
  Map<String, dynamic> _buildStepConfig(
    WorkflowRun run,
    WorkflowDefinition definition,
    WorkflowStep step,
    ResolvedStepConfig resolved,
    WorkflowContext context, {
    required String resolvedWorktreeMode,
    required String effectivePromotion,
  }) => workflow_task_factory.buildStepConfig(
    run,
    definition,
    step,
    resolved,
    context,
    resolvedWorktreeMode: resolvedWorktreeMode,
    effectivePromotion: effectivePromotion,
    workflowWorkspaceDir: _resolveWorkflowWorkspaceDir(),
  );

  String _resolvedWorktreeModeForScope(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    int? enclosingMaxParallel,
  }) => step_config_policy.resolveWorktreeModeForScope(
    definition,
    step,
    context,
    roleDefaults: _roleDefaults,
    enclosingMaxParallel: enclosingMaxParallel,
    templateEngine: _templateEngine,
  );

  String _effectivePromotion(WorkflowGitStrategy? strategy, {required String resolvedWorktreeMode}) =>
      step_config_policy.effectivePromotion(strategy, resolvedWorktreeMode: resolvedWorktreeMode);

  bool _stepNeedsWorktree(
    WorkflowDefinition definition,
    WorkflowStep step,
    ResolvedStepConfig resolved, {
    required String resolvedWorktreeMode,
  }) => step_config_policy.stepNeedsWorktree(definition, step, resolved, resolvedWorktreeMode: resolvedWorktreeMode);

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

  bool _shouldBindWorkflowProject(WorkflowDefinition definition, WorkflowStep step, ResolvedStepConfig resolved) =>
      step_config_policy.shouldBindWorkflowProject(definition, step, resolved);

  bool _stepTouchesProjectBranch(WorkflowDefinition definition, WorkflowStep step) {
    return step_config_policy.stepTouchesProjectBranch(definition, step, roleDefaults: _roleDefaults);
  }

  String _continueSessionRootStepId(WorkflowDefinition definition, WorkflowStep step) =>
      _resolveContinueSessionRootStep(definition, step)?.id ?? step.id;

  Future<String?> _promoteWorkflowTask({
    required WorkflowRun run,
    required WorkflowStep step,
    required Task task,
    required WorkflowContext context,
    required Map<String, dynamic> outputs,
    required String? projectId,
    required String promotionStrategy,
  }) async {
    if (task.type != TaskType.coding || promotionStrategy == 'none') {
      return null;
    }

    final promote = _turnAdapter?.promoteWorkflowBranch;
    if (promote == null) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: host promotion callback is not configured';
    }

    final promotionProjectId = projectId?.trim();
    if (promotionProjectId == null || promotionProjectId.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: step has no project binding';
    }

    final branch = (task.worktreeJson?['branch'] as String?)?.trim();
    if (branch == null || branch.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: task worktree branch is unavailable';
    }

    final integrationBranch = (context['_workflow.git.integration_branch'] as String?)?.trim();
    if (integrationBranch == null || integrationBranch.isEmpty) {
      outputs['${step.id}.promotion'] = 'failed';
      return 'promotion failed: integration branch is not initialized';
    }

    final promotionResult = await promote(
      runId: run.id,
      projectId: promotionProjectId,
      branch: branch,
      integrationBranch: integrationBranch,
      strategy: promotionStrategy,
    );

    switch (promotionResult) {
      case WorkflowGitPromotionSuccess(:final commitSha):
        outputs['${step.id}.promotion'] = 'success';
        outputs['${step.id}.promotion_sha'] = commitSha;
        return null;
      case WorkflowGitPromotionConflict(:final conflictingFiles, :final details):
        outputs['${step.id}.promotion'] = 'conflict';
        outputs['${step.id}.promotion_details'] = details;
        final summary = conflictingFiles.isEmpty ? 'merge conflict' : conflictingFiles.join(', ');
        return 'promotion-conflict: $summary';
      case WorkflowGitPromotionError(:final message):
        outputs['${step.id}.promotion'] = 'failed';
        return 'promotion failed: $message';
    }
  }

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
    WorkflowContext context,
  ) {
    final planPath = (outputs['plan'] as String?)?.trim();
    final planDir = (planPath == null || planPath.isEmpty) ? '' : p.dirname(planPath);
    final projectIndex = context['project_index'];
    final projectRoot = switch (projectIndex) {
      final Map<dynamic, dynamic> map => map['project_root'] as String?,
      _ => null,
    };

    final validation = step_outcome_normalizer.validateStorySpecOutputs(
      outputs,
      planDir: planDir,
      projectRoot: projectRoot,
    );
    final validationFailure = validation.validationFailure;
    if (validationFailure != null) {
      WorkflowExecutor._log.severe("Workflow '${run.id}': step '${step.id}': ${validationFailure.reason}");
    }
    return validation;
  }

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

  /// Returns true if the workflow-level budget has been exceeded.
  bool _workflowBudgetExceeded(WorkflowRun run, WorkflowDefinition definition) =>
      workflow_budget_monitor.workflowBudgetExceeded(run, definition);

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
  /// Deduplicated via `_budget.warningFired` in [run.contextJson] — fires once per run.
  /// Returns updated [run] if the flag was set, otherwise returns [run] unchanged.
  Future<WorkflowRun> _checkWorkflowBudgetWarning(WorkflowRun run, WorkflowDefinition definition) =>
      workflow_budget_monitor.checkWorkflowBudgetWarning(
        run: run,
        definition: definition,
        eventBus: _eventBus,
        repository: _repository,
      );

  /// Reads the step's cumulative token count from session KV or task metadata.
  ///
  /// For [continueSession] steps, subtracts the baseline stored in
  /// [Task.configJson]['_sessionBaselineTokens'] so workflow totals only reflect
  /// new turns, not the full shared-session history.
  Future<int> _readStepTokenCount(Task task) => workflow_budget_monitor.readStepTokenCount(task, _kvService);

  /// Reads the raw cumulative token total for [sessionId] from KV store.
  Future<int> _readSessionTokens(String sessionId) => workflow_budget_monitor.readSessionTokens(_kvService, sessionId);

  String? _resolveProjectId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required ResolvedStepConfig resolved,
  }) {
    final explicitProject = _resolveProjectTemplate(step.project, context);
    if (explicitProject != null) return explicitProject;
    if (!_shouldBindWorkflowProject(definition, step, resolved)) {
      return null;
    }
    return _resolveProjectTemplate(definition.project, context);
  }

  String? _resolveProjectIdWithMap(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
    MapContext mapContext, {
    required ResolvedStepConfig resolved,
  }) {
    final explicitProject = _resolveProjectTemplateWithMap(step.project, context, mapContext);
    if (explicitProject != null) return explicitProject;
    if (!_shouldBindWorkflowProject(definition, step, resolved)) {
      return null;
    }
    return _resolveProjectTemplateWithMap(definition.project, context, mapContext);
  }

  String? _resolveProjectTemplate(String? template, WorkflowContext context) {
    if (template == null) return null;
    final resolved = _templateEngine.resolve(template, context).trim();
    return resolved.isEmpty ? null : resolved;
  }

  String? _resolveProjectTemplateWithMap(String? template, WorkflowContext context, MapContext mapContext) {
    if (template == null) return null;
    final resolved = _templateEngine.resolveWithMap(template, context, mapContext).trim();
    return resolved.isEmpty ? null : resolved;
  }

  /// Resolves the effective provider for a continued session step.
  ///
  /// Session continuity requires the same provider family (e.g. both `codex`).
  /// If the current step's resolved provider matches the root step's family,
  /// the root's provider is used (the session thread belongs to it). If the
  /// families differ, the root's provider is used with a warning – the step
  /// cannot resume a thread from a different provider.
  ///
  /// The current step's **model** is preserved regardless – models can switch
  /// between turns within the same provider session.
  String? _resolveContinueSessionProvider(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowStep rootStep,
    ResolvedStepConfig resolved,
  ) {
    final rootResolved = resolveStepConfig(rootStep, definition.stepDefaults, roleDefaults: _roleDefaults);
    final rootProvider = rootResolved.provider;
    final stepProvider = resolved.provider;

    if (stepProvider != null && rootProvider != null) {
      final rootFamily = ProviderIdentity.family(rootProvider);
      final stepFamily = ProviderIdentity.family(stepProvider);
      if (rootFamily != stepFamily) {
        WorkflowExecutor._log.warning(
          'Step "${step.id}" uses continueSession but its resolved provider "$stepProvider" '
          '(family: $stepFamily) differs from root step "${rootStep.id}" provider "$rootProvider" '
          '(family: $rootFamily). Falling back to root provider "$rootProvider" for session continuity.',
        );
      }
    }

    return rootProvider;
  }

  String? _resolveContinueSessionRootProviderSessionId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
  ) {
    final rootStep = _resolveContinueSessionRootStep(definition, step);
    if (rootStep == null) return null;
    final raw = context['${rootStep.id}.providerSessionId'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  List<String> _buildOneShotFollowUpPrompts(
    WorkflowStep step,
    WorkflowContext context,
    Map<String, OutputConfig>? effectiveOutputs, {
    required List<String> contextOutputs,
    MapContext? mapCtx,
  }) => workflow_task_factory.buildOneShotFollowUpPrompts(
    step,
    context,
    effectiveOutputs,
    contextOutputs: contextOutputs,
    mapCtx: mapCtx,
    templateEngine: _templateEngine,
    skillPromptBuilder: _skillPromptBuilder,
  );

  Map<String, dynamic>? _buildStructuredOutputEnvelopeSchema(WorkflowStep step) =>
      workflow_task_factory.buildStructuredOutputEnvelopeSchema(step, _effectiveOutputsFor(step));

  WorkflowStep? _resolveContinueSessionRootStep(WorkflowDefinition definition, WorkflowStep step) {
    final visited = <String>{step.id};
    var current = step;

    while (current.continueSession != null) {
      final targetStepId = _resolveContinueSessionTargetStepId(definition, current);
      if (targetStepId == null || !visited.add(targetStepId)) {
        return null;
      }
      final targetStep = definition.steps.where((candidate) => candidate.id == targetStepId).firstOrNull;
      if (targetStep == null) return null;
      if (targetStep.continueSession == null) return targetStep;
      current = targetStep;
    }

    return null;
  }

  String? _resolveContinueSessionRootSessionId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
  ) {
    final rootStep = _resolveContinueSessionRootStep(definition, step);
    if (rootStep == null) return null;
    final raw = context['${rootStep.id}.sessionId'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  String? _resolveContinueSessionTargetStepId(WorkflowDefinition definition, WorkflowStep step) {
    final ref = step.continueSession;
    if (ref == null) return null;
    if (ref == '@previous') {
      final idx = definition.steps.indexWhere((candidate) => candidate.id == step.id);
      return idx > 0 ? definition.steps[idx - 1].id : null;
    }
    return ref;
  }

  void dispose() {
    approval_step_runner.cancelApprovalTimers(_approvalTimers);
  }

  /// Persists [context] to `<dataDir>/workflows/runs/<runId>/context.json` atomically.
  Future<void> _persistContext(String runId, WorkflowContext context) async {
    final dir = Directory(p.join(_dataDir, 'workflows', 'runs', runId));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'context.json'));
    await atomicWriteJson(file, context.toJson());
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
        requiresPerMapItemBootstrap: _requiresPerMapItemBootstrap,
      );

  String? _workflowProjectId(WorkflowRun run, WorkflowContext context) {
    final fromContext = context.variables['PROJECT']?.trim();
    if (fromContext != null && fromContext.isNotEmpty) return fromContext;
    final fromRun = run.variablesJson['PROJECT']?.trim();
    if (fromRun != null && fromRun.isNotEmpty) return fromRun;
    return null;
  }
}
