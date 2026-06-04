import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, ProviderIdentity;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowSkillPreflightConfig;

WorkflowSkillPreflightConfig buildWorkflowSkillPreflightConfig(DartclawConfig config) {
  final providers = <String>{config.agent.provider, ...config.providers.entries.keys};
  return WorkflowSkillPreflightConfig(
    defaultProvider: config.agent.provider,
    configuredProviders: providers,
    providerExecutables: {
      for (final providerId in providers) providerId: resolveWorkflowProviderExecutable(config, providerId),
    },
    providerOptions: {for (final providerId in providers) providerId: workflowProviderOptions(config, providerId)},
  );
}

String resolveWorkflowProviderExecutable(DartclawConfig config, String providerId) {
  final entry = config.providers[providerId];
  if (entry != null) return entry.executable;
  return switch (ProviderIdentity.family(providerId)) {
    'claude' => config.server.claudeExecutable,
    'codex' => 'codex',
    _ => providerId,
  };
}

Map<String, dynamic> workflowProviderOptions(DartclawConfig config, String providerId) =>
    config.providers[providerId]?.options ?? const <String, dynamic>{};
