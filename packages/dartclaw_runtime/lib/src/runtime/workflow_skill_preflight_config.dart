import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowSkillPreflightConfig;

import '../execution_policy_resolver.dart';
import 'provider_resolution.dart';

/// [bundledSkills] are the DartClaw-native skills task worktrees carry; when
/// workflow steps resolve to container execution they are all a step can
/// activate.
WorkflowSkillPreflightConfig buildWorkflowSkillPreflightConfig(
  DartclawConfig config, {
  Set<String> bundledSkills = const <String>{},
}) {
  final providers = <String>{config.agent.provider, ...config.providers.entries.keys};
  final targets = {for (final providerId in providers) providerId: resolveProviderTarget(config, providerId)};
  return WorkflowSkillPreflightConfig(
    defaultProvider: config.agent.provider,
    configuredProviders: providers,
    providerExecutables: {for (final entry in targets.entries) entry.key: entry.value.executable},
    providerOptions: {for (final entry in targets.entries) entry.key: entry.value.options},
    containerVisibleSkills: _workflowStepsRunInContainer(config) ? Set.unmodifiable(bundledSkills) : null,
  );
}

/// Workflow steps are tasks without a declared profile, so they take the task
/// lane's placement. Every profile counts as available: an enabled config
/// whose runtime cannot run containers is refused at startup instead of
/// falling back to the host.
bool _workflowStepsRunInContainer(DartclawConfig config) {
  try {
    return ExecutionPolicyResolver(
      config: config,
      availableContainerProfiles: containerSecurityProfiles,
    ).resolveForTask().isContainer;
  } on ExecutionPolicyException {
    // Dispatch refuses every step with this same error.
    return false;
  }
}
