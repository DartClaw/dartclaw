import 'package:dartclaw_core/dartclaw_core.dart' show ProviderExecutionSupport;

import 'acp_config.dart';

/// Returns the startup-fatal error for an ACP registration that requires a
/// container boundary this release cannot mediate, or `null` when [agent]
/// requires none.
///
/// A registration requires one either by asking for it outright or by claiming
/// no guard mediation — a relay or unverified topology has no other boundary.
/// The rule is enforced here rather than only in YAML validation so a
/// programmatically built registration cannot bypass it. This is a deliberate
/// breaking change: the previous behavior silently discarded the required
/// boundary and injected the host provider credential into the container's
/// environment.
///
/// The missing mechanism is read off `ProviderExecutionSupport.acp`, which is
/// the same record every launch surface consults, so the refusal and the
/// compatibility verdict can never name different gaps.
String? acpContainerRequirementError(String providerId, AcpAgentConfig agent) {
  final isDirect = agent.topology == AcpAgentTopology.direct;
  if (isDirect && !agent.containerIsolationRequired) return null;
  final path = isDirect ? 'container_isolation_required' : 'topology';
  final gap = ProviderExecutionSupport.acp(providerId).containerMediationGap;
  return 'Invalid harness.acp.agents.$providerId.$path: DartClaw provides no $gap, so an ACP '
      'registration that requires a container boundary has no runnable execution. Remove the registration, or — if '
      'you have established that this agent is safe to run directly on the host — declare it with topology: direct '
      'and container_isolation_required: false. DartClaw validates that declaration only when the registration also '
      'sets requires_guard_mediation: true.';
}
