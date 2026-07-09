import 'workflow_definition.dart'
    show OutputConfig, OutputFormat, WorkflowDefinition, WorkflowGitStrategy, WorkflowStep, WorkflowTaskType;

import 'step_config_resolver.dart';
import 'workflow_context.dart';
import 'workflow_template_engine.dart';

/// Resolves the effective worktree mode for a (possibly null) [strategy].
///
/// A null strategy is treated as the default [WorkflowGitStrategy] (`auto`),
/// identical to an authored `gitStrategy: { worktree: auto }`: a parallel
/// map/foreach scope resolves to `per-map-item` (isolated per-iteration
/// worktrees), serial and non-map scopes to `inline`. Collapsing null to a
/// literal `inline` would deny a strategy-less definition its per-item
/// isolation, so concurrent iterations would share — and clobber — the live
/// checkout. This is the single resolution seam; every caller routes through it
/// so the dispatcher's worktree provisioning and the iteration concurrency
/// clamp agree on one value.
String resolveWorktreeMode(WorkflowGitStrategy? strategy, {required int? maxParallel, required bool isMap}) =>
    (strategy ?? const WorkflowGitStrategy()).effectiveWorktreeMode(maxParallel: maxParallel, isMap: isMap);

/// Resolves the effective worktree mode for a step in its current scope.
String resolveWorktreeModeForScope(
  WorkflowDefinition definition,
  WorkflowStep step,
  WorkflowContext context, {
  required WorkflowRoleDefaults roleDefaults,
  int? enclosingMaxParallel,
  bool enclosingMapScope = false,
  WorkflowTemplateEngine? templateEngine,
}) {
  final isMapScope = step.mapOver != null || enclosingMapScope || enclosingMaxParallel != null;
  final maxParallel = switch ((step.mapOver != null, enclosingMapScope || enclosingMaxParallel != null)) {
    (false, false) => null,
    (true, false) => resolveMaxParallel(step.maxParallel, context, step.id, templateEngine: templateEngine),
    _ => enclosingMaxParallel,
  };
  return resolveWorktreeMode(definition.gitStrategy, maxParallel: maxParallel, isMap: isMapScope);
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
  Map<String, OutputConfig>? effectiveOutputs,
}) {
  if (resolvedWorktreeMode == 'per-map-item') return true;
  if (step.isForeachController) return false;
  if (!shouldBindWorkflowProject(definition, step, resolved, effectiveOutputs: effectiveOutputs)) return false;
  if (stepEmitsArtifactPath(step, effectiveOutputs: effectiveOutputs)) return true;
  final allowedTools = resolved.allowedTools;
  if (allowedTools != null) {
    return _allowsProjectMutation(allowedTools);
  }
  return step.taskType == WorkflowTaskType.agent;
}

/// Returns true when a step should be executed without write tools.
bool stepIsReadOnly(WorkflowStep step, ResolvedStepConfig resolved) {
  final allowedTools = resolved.allowedTools;
  if (allowedTools != null) {
    return !_allowsProjectMutation(allowedTools);
  }
  return false;
}

/// Returns true when any declared output is an artifact path.
bool stepEmitsArtifactPath(WorkflowStep step, {Map<String, OutputConfig>? effectiveOutputs}) =>
    (effectiveOutputs ?? step.outputs)?.values.any((config) => config.format == OutputFormat.path) ?? false;

/// Returns true when a workflow task should bind to a project checkout.
///
/// Binding flows from explicit project-affecting step config: map scope,
/// artifact-path outputs, mutating `allowedTools`, or a neutral agent step.
/// Retired inputs such as `project_index` do not trigger binding.
bool shouldBindWorkflowProject(
  WorkflowDefinition definition,
  WorkflowStep step,
  ResolvedStepConfig resolved, {
  Map<String, OutputConfig>? effectiveOutputs,
}) {
  if (definition.project == null) return false;
  if (step.isMapStep) return true;
  if (stepEmitsArtifactPath(step, effectiveOutputs: effectiveOutputs)) return true;
  final allowedTools = resolved.allowedTools;
  if (allowedTools != null) {
    return _allowsProjectMutation(allowedTools);
  }
  return step.taskType == WorkflowTaskType.agent;
}

/// Returns true when the step can mutate the workflow project branch.
bool stepTouchesProjectBranch(
  WorkflowDefinition definition,
  WorkflowStep step, {
  required WorkflowRoleDefaults roleDefaults,
}) {
  if (definition.project == null) return false;
  final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: roleDefaults);
  if (!shouldBindWorkflowProject(definition, step, resolved)) return false;
  if (step.isForeachController) return false;
  return !stepIsReadOnly(step, resolved);
}

bool _allowsProjectMutation(List<String> allowedTools) =>
    allowedTools.contains('file_write') || allowedTools.contains('file_edit');

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

/// Returns true when per-map-item git isolation is required.
bool requiresPerMapItemGitIsolation(
  WorkflowDefinition definition,
  WorkflowContext context, {
  required WorkflowTemplateEngine templateEngine,
}) {
  for (final step in definition.steps.where((candidate) => candidate.mapOver != null)) {
    int? maxParallel;
    try {
      maxParallel = resolveMaxParallel(step.maxParallel, context, step.id, templateEngine: templateEngine);
    } on ArgumentError {
      maxParallel = 2;
    }
    if (resolveWorktreeMode(definition.gitStrategy, maxParallel: maxParallel, isMap: true) == 'per-map-item') {
      return true;
    }
  }
  return false;
}
