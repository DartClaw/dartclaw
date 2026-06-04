import 'package:dartclaw_config/dartclaw_config.dart' show ProviderIdentity;

import 'skill_introspector.dart';
import 'step_config_resolver.dart';
import 'step_config_policy.dart' as step_config_policy;
import 'workflow_context.dart';
import 'workflow_definition.dart';

final class WorkflowSkillPreflightResult {
  final Map<String, Map<String, String>> _visibleByProviderAndAuthored;

  const WorkflowSkillPreflightResult._(this._visibleByProviderAndAuthored);

  static const empty = WorkflowSkillPreflightResult._(<String, Map<String, String>>{});

  String visibleSkillFor({required String? provider, required String skill}) {
    if (provider == null || provider.trim().isEmpty) return skill;
    return _visibleByProviderAndAuthored[provider]?[skill] ?? skill;
  }
}

Future<WorkflowSkillPreflightResult> preflightWorkflowSkillRefs({
  required WorkflowDefinition definition,
  required SkillIntrospector? introspector,
  required WorkflowSkillPreflightConfig skillPreflightConfig,
  required WorkflowRoleDefaults roleDefaults,
  required WorkflowContext context,
}) async {
  if (introspector == null) return WorkflowSkillPreflightResult.empty;

  final refsByProvider = <String, Set<String>>{};

  void addSkillRef(WorkflowStep step, String skill) {
    final resolved = resolveStepConfig(step, definition.stepDefaults, roleDefaults: roleDefaults);
    final provider = _effectivePreflightProvider(
      definition: definition,
      step: step,
      resolved: resolved,
      roleDefaults: roleDefaults,
      defaultProvider: skillPreflightConfig.defaultProvider,
    )?.trim();
    if (provider == null || provider.isEmpty) {
      throw WorkflowPreflightException(
        'Step "${step.id}" references skill "$skill" but no provider is configured for runtime preflight.',
      );
    }
    if (!skillPreflightConfig.isProviderConfigured(provider)) {
      throw WorkflowPreflightException(
        'Step "${step.id}" references skill "$skill" for provider "$provider", '
        'but provider "$provider" is not configured for runtime preflight.',
      );
    }
    refsByProvider.putIfAbsent(provider, () => <String>{}).add(skill);
  }

  for (final step in definition.steps) {
    final skill = step.skill;
    if (skill == null || step.taskType != WorkflowTaskType.agent) continue;
    addSkillRef(step, skill);
  }

  for (final step in _syntheticSkillSteps(definition, context: context, roleDefaults: roleDefaults)) {
    addSkillRef(step, step.skill!);
  }

  final visibleByProviderAndAuthored = <String, Map<String, String>>{};
  for (final entry in refsByProvider.entries) {
    final provider = entry.key;
    final executable = skillPreflightConfig.executableFor(provider);
    final providerOptions = skillPreflightConfig.optionsFor(provider);
    final Set<String> available;
    try {
      available = await introspector.listAvailable(
        provider: provider,
        executable: executable,
        providerOptions: providerOptions,
      );
    } on WorkflowPreflightException {
      rethrow;
    } catch (e) {
      final executableContext = executable == null ? '' : ' using "$executable"';
      throw WorkflowPreflightException('Skill introspection failed for provider "$provider"$executableContext: $e');
    }
    // Resolve the effective family the same way the introspector probed for
    // skills (configured family option, then executable-name fallback) so a
    // custom provider alias that wraps codex translates `andthen:*` skill refs
    // instead of being rejected.
    final family = ProviderIdentity.resolveFamily(provider, options: providerOptions, executable: executable);
    final visibleByAuthored = <String, String>{};
    final missing = <String>[];
    for (final skill in entry.value) {
      final visible = _providerVisibleSkillName(family: family, authoredSkill: skill, available: available);
      if (visible == null) {
        missing.add(_missingSkillLabel(family: family, authoredSkill: skill));
      } else {
        visibleByAuthored[skill] = visible;
      }
    }
    missing.sort();
    if (missing.isNotEmpty) {
      throw WorkflowPreflightException(
        'Missing skills for provider "$provider": ${missing.join(', ')}. '
        'Available: ${available.length} skills.',
      );
    }
    visibleByProviderAndAuthored[provider] = visibleByAuthored;
  }
  return WorkflowSkillPreflightResult._(visibleByProviderAndAuthored);
}

String? _providerVisibleSkillName({
  required String family,
  required String authoredSkill,
  required Set<String> available,
}) {
  if (available.contains(authoredSkill)) return authoredSkill;
  for (final candidate in _providerVisibleSkillCandidates(family: family, authoredSkill: authoredSkill)) {
    if (available.contains(candidate)) return candidate;
  }
  return null;
}

String _missingSkillLabel({required String family, required String authoredSkill}) {
  final candidates = _providerVisibleSkillCandidates(family: family, authoredSkill: authoredSkill).toList();
  if (candidates.isEmpty) return authoredSkill;
  return '$authoredSkill (searched as ${candidates.join(', ')})';
}

Iterable<String> _providerVisibleSkillCandidates({required String family, required String authoredSkill}) sync* {
  if (family == ProviderIdentity.codex && authoredSkill.startsWith('andthen:')) {
    yield 'andthen-${authoredSkill.substring('andthen:'.length)}';
  }
}

String? _effectivePreflightProvider({
  required WorkflowDefinition definition,
  required WorkflowStep step,
  required ResolvedStepConfig resolved,
  required WorkflowRoleDefaults roleDefaults,
  required String? defaultProvider,
}) {
  final rootStep = step.continueSession == null ? null : _resolveContinueSessionRootStep(definition, step);
  if (rootStep == null) return resolved.provider ?? defaultProvider;
  final rootResolved = resolveStepConfig(rootStep, definition.stepDefaults, roleDefaults: roleDefaults);
  return rootResolved.provider ?? resolved.provider ?? defaultProvider;
}

WorkflowStep? _resolveContinueSessionRootStep(WorkflowDefinition definition, WorkflowStep step) {
  final visited = <String>{step.id};
  var current = step;

  while (current.continueSession != null) {
    final targetStepId = _resolveContinueSessionTargetStepId(definition, current);
    if (targetStepId == null || !visited.add(targetStepId)) return null;
    final targetStep = definition.steps.where((candidate) => candidate.id == targetStepId).firstOrNull;
    if (targetStep == null) return null;
    if (targetStep.continueSession == null) return targetStep;
    current = targetStep;
  }

  return null;
}

String? _resolveContinueSessionTargetStepId(WorkflowDefinition definition, WorkflowStep step) {
  final ref = step.continueSession;
  if (ref == null) return null;
  if (ref != '@previous') return ref;
  final index = definition.steps.indexWhere((candidate) => candidate.id == step.id);
  if (index <= 0) return null;
  return definition.steps[index - 1].id;
}

Iterable<WorkflowStep> _syntheticSkillSteps(
  WorkflowDefinition definition, {
  required WorkflowContext context,
  required WorkflowRoleDefaults roleDefaults,
}) sync* {
  final strategy = definition.gitStrategy;
  if (strategy?.mergeResolve.enabled != true) return;
  final stepById = {for (final step in definition.steps) step.id: step};
  for (final step in definition.steps) {
    if (!step.isForeachController) continue;
    final childSteps = step.foreachSteps?.map((id) => stepById[id]).nonNulls.toList(growable: false) ?? const [];
    final hasCodingSteps = childSteps.any(
      (child) => step_config_policy.stepTouchesProjectBranch(definition, child, roleDefaults: roleDefaults),
    );
    int? maxParallel;
    try {
      maxParallel = step_config_policy.resolveMaxParallel(step.maxParallel, context, step.id);
    } on ArgumentError {
      continue;
    }
    final resolvedWorktreeMode = strategy!.effectiveWorktreeMode(maxParallel: maxParallel, isMap: true);
    final promotionAware = step_config_policy.isPromotionAwareScope(
      strategy,
      resolvedWorktreeMode: resolvedWorktreeMode,
      hasCodingSteps: hasCodingSteps,
    );
    if (promotionAware) {
      yield WorkflowStep(
        id: '_merge_resolve_${step.id}_0_1',
        name: 'merge-resolve preflight',
        skill: 'dartclaw-merge-resolve',
        prompts: const ['preflight'],
      );
    }
  }
}
