import 'package:dartclaw_config/dartclaw_config.dart' show ProviderIdentity;

import '../skills/provider_auth_preflight.dart';
import 'skill_introspector.dart';
import 'step_config_resolver.dart';
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
  ProviderAuthPreflight? providerAuthPreflight,
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

  for (final step in syntheticWorkflowSkillSteps(definition, context: context, roleDefaults: roleDefaults)) {
    addSkillRef(step, step.skill!);
  }

  // Probe provider auth over the same referenced-provider set, before any skill
  // introspection spawn, so a logged-out CLI aborts with actionable guidance
  // instead of surfacing a cryptic mid-introspection 401.
  if (providerAuthPreflight != null) {
    await _preflightProviderAuth(providerAuthPreflight, refsByProvider.keys, skillPreflightConfig);
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
    // custom provider alias that wraps codex translates namespaced skill refs
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

Future<void> _preflightProviderAuth(
  ProviderAuthPreflight preflight,
  Iterable<String> providers,
  WorkflowSkillPreflightConfig config,
) async {
  for (final provider in providers) {
    final result = await preflight.evaluate(
      provider: provider,
      executable: config.executableFor(provider),
      providerOptions: config.optionsFor(provider),
    );
    if (!result.authenticated) {
      throw WorkflowPreflightException(
        result.remediationMessage ?? 'Workflow provider "$provider" is not authenticated.',
      );
    }
  }
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
  // The codex family exposes namespaced skills (`<ns>:<skill>`) under a
  // hyphenated provider-visible name (`<ns>-<skill>`). Generalize over any
  // namespace prefix so the translation carries no framework-specific literal
  // while remaining behavior-preserving for existing refs.
  if (family != ProviderIdentity.codex) return;
  final separator = authoredSkill.indexOf(':');
  if (separator <= 0 || separator == authoredSkill.length - 1) return;
  yield '${authoredSkill.substring(0, separator)}-${authoredSkill.substring(separator + 1)}';
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
