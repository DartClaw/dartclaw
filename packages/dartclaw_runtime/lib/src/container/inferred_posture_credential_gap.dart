import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../execution_policy_resolver.dart';
import '../runtime/provider_resolution.dart';

/// The default provider's missing container credential, when it is what makes
/// an inferred container posture decline.
///
/// [config] carries the posture [resolveContainerPosture] settled. Only an
/// inferred posture (`container.enabled` undeclared) that resolved to enabled
/// can decline: an explicit `true` refuses at startup instead, and ACP's
/// `container_isolation_required` stays fail-closed. Placement comes from
/// [ExecutionPolicyResolver], so `agent.execution: host` needs no container
/// credential. Only the first-party Claude and Codex families are judged: a
/// registrar-owned provider carries its own authentication, which this seam
/// cannot see.
///
/// Answers the provider and the [ProviderValidator.credentialRefusalFor]
/// remediation, or `null` when containers stay on. Wiring and `doctor` both ask
/// here, so a prediction cannot drift from what `serve` does.
Future<({String providerId, String remediation})?> inferredPostureCredentialGap(
  DartclawConfig config, {
  required CredentialRegistry registry,
}) async {
  if (!config.container.enabled || config.container.declaredEnabled != null) return null;

  final providerId = ProviderIdentity.normalize(config.agent.provider);
  if (!primaryRunsInContainer(config, providerId)) return null;

  final target = resolveProviderTarget(config, providerId);
  if (target.family != ProviderIdentity.claude && target.family != ProviderIdentity.codex) return null;
  final remediation = await ProviderValidator.credentialRefusalFor(
    providerId: providerId,
    provider: config.providers[providerId] ?? ProviderEntry(executable: target.executable),
    registry: registry,
    hostExecution: false,
    credentialsDir: config.credentialsDir,
  );
  return remediation == null ? null : (providerId: providerId, remediation: remediation);
}

/// Whether [providerId]'s primary placement under [config]'s settled posture is
/// a container.
///
/// The profile ids are the ones container wiring registers; the resolver is
/// built here, before `HarnessWiring` has one. A placement with no host
/// equivalent counts as host, as `HarnessWiring` reads it: that case is refused
/// at authority registration, and credential-wise it is the host.
bool primaryRunsInContainer(DartclawConfig config, String providerId) {
  final resolver = ExecutionPolicyResolver(
    config: config,
    availableContainerProfiles: config.container.enabled ? containerSecurityProfiles : const {},
  );
  try {
    return resolver.resolveForPrimary(providerId: providerId).isContainer;
  } on ExecutionPolicyException {
    return false;
  }
}
