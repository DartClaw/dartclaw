import 'package:dartclaw_models/dartclaw_models.dart'
    show OutputFormat, WorkflowDefinition, WorkflowGitStrategy, WorkflowStep;

import 'step_config_resolver.dart';
import 'workflow_context.dart';
import 'workflow_template_engine.dart';

/// Resolves the effective worktree mode for a step in its current scope.
String resolveWorktreeModeForScope(
  WorkflowDefinition definition,
  WorkflowStep step,
  WorkflowContext context, {
  required WorkflowRoleDefaults roleDefaults,
  int? enclosingMaxParallel,
  WorkflowTemplateEngine? templateEngine,
}) {
  final strategy = definition.gitStrategy;
  if (strategy == null) return 'inline';
  final isMapScope = step.mapOver != null || enclosingMaxParallel != null;
  final maxParallel = isMapScope
      ? (enclosingMaxParallel ?? resolveMaxParallel(step.maxParallel, context, step.id, templateEngine: templateEngine))
      : null;
  return strategy.effectiveWorktreeMode(maxParallel: maxParallel, isMap: isMapScope);
}

/// Resolves the promotion strategy implied by the worktree mode.
String effectivePromotion(WorkflowGitStrategy? strategy, {required String resolvedWorktreeMode}) {
  final explicit = strategy?.promotion?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }
  return switch (resolvedWorktreeMode) {
    'per-map-item' || 'per-task' => 'merge',
    _ => 'none',
  };
}

/// Returns true when the step needs a task worktree.
bool stepNeedsWorktree(
  WorkflowDefinition definition,
  WorkflowStep step,
  ResolvedStepConfig resolved, {
  required String resolvedWorktreeMode,
}) {
  if (resolvedWorktreeMode == 'per-map-item') return true;
  if (step.isForeachController || step.outputKeys.contains('project_index')) return false;
  if (step.project != null) return true;
  if (!shouldBindWorkflowProject(definition, step, resolved)) return false;
  final allowedTools = resolved.allowedTools;
  if (allowedTools != null) {
    return allowedTools.contains('file_write');
  }
  return step.type == 'custom';
}

/// Returns true when a step should be executed without write tools.
bool stepIsReadOnly(WorkflowStep step, ResolvedStepConfig resolved) {
  final allowedTools = resolved.allowedTools;
  if (allowedTools != null) {
    return !allowedTools.contains('file_write');
  }
  if (!step.typeAuthored) {
    return step.type == 'research' || step.type == 'analysis';
  }
  return false;
}

/// Returns true when any declared output is an artifact path.
bool stepEmitsArtifactPath(WorkflowStep step) =>
    step.outputs?.values.any((config) => config.format == OutputFormat.path) ?? false;

/// Returns true when a workflow task should bind to a project checkout.
bool shouldBindWorkflowProject(WorkflowDefinition definition, WorkflowStep step, ResolvedStepConfig resolved) {
  if (step.project != null) return true;
  if (definition.project == null) return false;
  if (step.isMapStep) return true;
  if (step.inputs.contains('project_index')) return true;
  if (step.outputKeys.contains('project_index')) return true;
  final allowedTools = resolved.allowedTools;
  if (allowedTools != null) {
    return allowedTools.contains('file_write');
  }
  return step.type == 'custom';
}

/// Returns true when the step can mutate the workflow project branch.
bool stepTouchesProjectBranch(
  WorkflowDefinition definition,
  WorkflowStep step, {
  required WorkflowRoleDefaults roleDefaults,
}) {
  if (definition.project == null && step.project == null) return false;
  final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: roleDefaults);
  if (!shouldBindWorkflowProject(definition, step, resolved)) return false;
  if (step.isForeachController || step.outputKeys.contains('project_index')) return false;
  return !stepIsReadOnly(step, resolved);
}

/// Resolves the runtime `maxParallel` value for map and foreach scopes.
int? resolveMaxParallel(Object? raw, WorkflowContext context, String stepId, {WorkflowTemplateEngine? templateEngine}) {
  if (raw == null) return 1;
  if (raw is int) return raw;
  if (raw is! String) return 1;

  final resolved = raw.contains('{{') ? (templateEngine ?? WorkflowTemplateEngine()).resolve(raw, context) : raw;

  if (resolved.toLowerCase() == 'unlimited') return null;
  final parsed = int.tryParse(resolved.trim());
  if (parsed != null) return parsed;
  throw ArgumentError(
    "Map step '$stepId': maxParallel '$raw' resolved to '$resolved' "
    'which is not an integer or "unlimited".',
  );
}

/// Returns true for promotion-aware per-map-item scopes.
bool isPromotionAwareScope(
  WorkflowGitStrategy? strategy, {
  required String resolvedWorktreeMode,
  required bool hasCodingSteps,
}) {
  if (!hasCodingSteps) return false;
  return resolvedWorktreeMode == 'per-map-item' &&
      effectivePromotion(strategy, resolvedWorktreeMode: resolvedWorktreeMode) != 'none';
}

/// Returns true when per-map-item git bootstrap is required.
bool requiresPerMapItemBootstrap(
  WorkflowDefinition definition,
  WorkflowContext context, {
  required WorkflowTemplateEngine templateEngine,
}) {
  final strategy = definition.gitStrategy;
  if (strategy == null) return false;
  for (final step in definition.steps.where((candidate) => candidate.mapOver != null)) {
    int? maxParallel;
    try {
      maxParallel = resolveMaxParallel(step.maxParallel, context, step.id, templateEngine: templateEngine);
    } on ArgumentError {
      maxParallel = 2;
    }
    final resolvedMode = strategy.effectiveWorktreeMode(maxParallel: maxParallel, isMap: true);
    if (resolvedMode == 'per-map-item') {
      return true;
    }
  }
  return false;
}
