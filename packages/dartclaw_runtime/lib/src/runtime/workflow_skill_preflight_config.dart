import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowSkillPreflightConfig;

import 'provider_resolution.dart';

WorkflowSkillPreflightConfig buildWorkflowSkillPreflightConfig(DartclawConfig config) {
  final providers = <String>{config.agent.provider, ...config.providers.entries.keys};
  final targets = {for (final providerId in providers) providerId: resolveProviderTarget(config, providerId)};
  return WorkflowSkillPreflightConfig(
    defaultProvider: config.agent.provider,
    configuredProviders: providers,
    providerExecutables: {for (final entry in targets.entries) entry.key: entry.value.executable},
    providerOptions: {for (final entry in targets.entries) entry.key: entry.value.options},
  );
}
