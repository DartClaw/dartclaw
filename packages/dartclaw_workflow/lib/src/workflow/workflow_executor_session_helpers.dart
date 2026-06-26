part of 'workflow_executor.dart';

extension WorkflowExecutorSessionHelpers on WorkflowExecutor {
  // ── Project ID resolution ───────────────────────────────────────────────────

  String? _resolveProjectId(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context, {
    required ResolvedStepConfig resolved,
    Map<String, OutputConfig>? effectiveOutputs,
  }) {
    if (!_shouldBindWorkflowProject(definition, step, resolved, effectiveOutputs: effectiveOutputs)) {
      return null;
    }
    return _resolveWorkflowProjectTemplate(definition.project, context);
  }

  String? _resolveProjectIdWithMap(
    WorkflowDefinition definition,
    WorkflowStep step,
    WorkflowContext context,
    MapContext mapContext, {
    required ResolvedStepConfig resolved,
    Map<String, OutputConfig>? effectiveOutputs,
  }) {
    if (!_shouldBindWorkflowProject(definition, step, resolved, effectiveOutputs: effectiveOutputs)) {
      return null;
    }
    return _resolveWorkflowProjectTemplateWithMap(definition.project, context, mapContext);
  }

  String? _resolveWorkflowProjectTemplate(String? template, WorkflowContext context) {
    if (template == null) return null;
    final String resolved;
    try {
      resolved = _templateEngine.resolve(template, context).trim();
    } on ArgumentError {
      // An optional, unset project variable (e.g. `{{PROJECT}}` in standalone/
      // inline runs with no registered project) means "no bound project", not a
      // run failure. Required variables are enforced at start; only optional
      // ones reach here unresolved.
      return null;
    }
    return resolved.isEmpty ? null : resolved;
  }

  String? _resolveWorkflowProjectTemplateWithMap(String? template, WorkflowContext context, MapContext mapContext) {
    if (template == null) return null;
    final String resolved;
    try {
      resolved = _templateEngine.resolveWithMap(template, context, mapContext).trim();
    } on ArgumentError {
      return null;
    }
    return resolved.isEmpty ? null : resolved;
  }

  // ── Session continuity ──────────────────────────────────────────────────────

  /// Resolves the effective provider for a continued session step.
  ///
  /// Session continuity requires the same provider family (e.g. both `codex`).
  /// If the families differ, the root's provider is used with a warning – the
  /// step cannot resume a thread from a different provider. The current step's
  /// **model** is preserved regardless.
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

  // ── One-shot follow-up + structured output helpers ──────────────────────────

  List<String> _buildOneShotFollowUpPrompts(
    WorkflowStep step,
    WorkflowContext context,
    Map<String, OutputConfig>? effectiveOutputs, {
    required List<String> outputKeys,
    MapContext? mapCtx,
  }) => workflow_task_factory.buildOneShotFollowUpPrompts(
    step,
    context,
    effectiveOutputs,
    outputKeys: outputKeys,
    mapCtx: mapCtx,
    templateEngine: _templateEngine,
    skillPromptBuilder: _skillPromptBuilder,
  );

  Map<String, dynamic>? _buildStructuredOutputEnvelopeSchema(WorkflowStep step) =>
      workflow_task_factory.buildStructuredOutputEnvelopeSchema(step, effectiveOutputsFor(step));
}
