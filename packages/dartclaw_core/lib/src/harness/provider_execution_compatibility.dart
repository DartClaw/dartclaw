import 'package:dartclaw_config/dartclaw_config.dart'
    show AcpAgentConfig, AcpAgentTopology, ExecutionPolicy, ProviderIdentity;

/// Container mediation an ACP client has in no release so far.
///
/// The host gateway's provider adapters are verified against the Claude and
/// Codex clients only, so an ACP binary inside a container can neither reach
/// its model provider nor an approved host capability.
const _acpContainerMediationGap = 'provider-credential or host-capability mediation for an ACP client';

/// Launch surface that starts a provider process.
///
/// The surfaces have separate launch implementations, so a provider is
/// available on one only when that implementation exists for it. An absent
/// implementation is a verdict both surfaces report identically, not a reason
/// to route the work through another provider's adapter.
enum ProviderLaunchSurface {
  /// Long-lived harnesses: the primary lane, logical agents, and ordinary tasks.
  longLived('long-lived'),

  /// Workflow-owned one-shot CLI turns.
  workflowOneShot('workflow one-shot');

  new(this.label);

  /// Operator-facing surface name used in diagnostics.
  final String label;
}

/// Why a provider cannot run a requested surface/execution combination.
enum ProviderUnavailability {
  /// The requested launch surface has no implementation for this provider.
  surface,

  /// Container execution has no credential or host-capability mediation.
  containerMediation,

  /// The credential `providers.<id>.auth` selects cannot be presented.
  credential,
}

/// Reports why [providerId] cannot present the credential this deployment
/// selected for it, or `null` when it can present one.
///
/// Credential state is live — a dedicated store is re-read per spawn and a
/// token can be re-issued without a restart — so admission consults a callback
/// rather than the startup snapshot the rest of the inventory holds. The
/// composition root owns the resolution and authors the message; this library
/// only carries the verdict.
typedef ProviderCredentialGate = String? Function(String providerId);

/// The compatibility verdict every launch surface consumes.
///
/// A verdict is computed after execution policy resolution and before process
/// admission; an unsupported combination is terminal and is never replaced by
/// a different boundary or another provider's adapter.
final class ProviderExecutionVerdict {
  /// The combination is runnable as requested.
  const new supported() : reason = null, message = '';

  /// [surface] has no launch implementation for [providerId].
  new unsupportedSurface({required String providerId, required ProviderLaunchSurface surface})
    : reason = ProviderUnavailability.surface,
      message =
          'Provider "$providerId" has no ${surface.label} launch implementation, so that surface is unavailable for '
          'it. Run this workload on a surface the provider implements, or select a provider implemented for the '
          '${surface.label} surface.';

  new _containerMediation(this.message) : reason = ProviderUnavailability.containerMediation;

  /// The deployment cannot present the credential selected for the provider.
  ///
  /// [message] comes from the composition root's single remediation author, so
  /// an operator meets the same fix here as at every other refusal.
  const new credentialUnavailable(this.message) : reason = ProviderUnavailability.credential;

  /// Why the combination is unavailable, or `null` when it is supported.
  final ProviderUnavailability? reason;

  /// Operator-actionable, secret-free diagnostic; empty when supported.
  final String message;

  /// Whether the requested combination may proceed to admission.
  bool get isSupported => reason == null;
}

/// One provider's computed launch compatibility for this release.
///
/// Compatibility is derived from what the deployment can actually enforce —
/// which surfaces implement the provider and whether its container execution
/// has credential and host-capability mediation — never from a topology label,
/// a profile ID, or the presence of a container manager.
final class ProviderExecutionSupport {
  /// Creates a support record.
  const new({
    required this.providerId,
    required this.surfaces,
    required this.registrationYamlPath,
    this.containerMediationGap,
  });

  /// Compatibility of a built-in provider adapter (Claude, Codex).
  ///
  /// Both surfaces implement it and both execution modes are mediated.
  new builtIn(String providerId)
    : this(
        providerId: providerId,
        surfaces: const {ProviderLaunchSurface.longLived, ProviderLaunchSurface.workflowOneShot},
        registrationYamlPath: 'providers.$providerId',
      );

  /// Compatibility computed for an ACP registration.
  ///
  /// Only the long-lived surface has an ACP launch implementation, and no ACP
  /// container combination is mediated. A registration that *requires* a
  /// container therefore has no runnable combination at all — see
  /// [acpContainerRequirementError], which rejects it at startup.
  new acp(String providerId)
    : this(
        providerId: providerId,
        surfaces: const {ProviderLaunchSurface.longLived},
        registrationYamlPath: 'harness.acp.agents.$providerId',
        containerMediationGap: _acpContainerMediationGap,
      );

  /// Provider identity this record describes.
  final String providerId;

  /// Launch surfaces with an implementation for [providerId].
  final Set<ProviderLaunchSurface> surfaces;

  /// Exact configuration path this provider is registered at.
  final String registrationYamlPath;

  /// The container mediation this provider lacks, or `null` when its container
  /// execution is fully mediated.
  ///
  /// Non-null makes every container combination unavailable for it.
  final String? containerMediationGap;

  /// Returns the verdict for launching [providerId] on [surface] under [policy].
  ///
  /// The message names the provider, the requested mode and profile, the
  /// registration path, the missing mechanism, and the accepted remediation —
  /// and is determined by those alone, so a caller may emit one warning per
  /// distinct unavailable combination.
  ProviderExecutionVerdict verdictFor({required ProviderLaunchSurface surface, required ExecutionPolicy policy}) {
    if (!surfaces.contains(surface)) {
      return ProviderExecutionVerdict.unsupportedSurface(providerId: providerId, surface: surface);
    }
    final gap = containerMediationGap;
    if (gap == null || !policy.isContainer) return const ProviderExecutionVerdict.supported();
    return ProviderExecutionVerdict._containerMediation(
      'Provider "$providerId" cannot run as ${policy.describe()}: DartClaw provides no $gap, so every container '
      'combination is unavailable for it (registered at $registrationYamlPath). Select host execution for it via '
      'agent.execution, agent.agents.<id>.execution, or tasks.execution.<task-type>, or run this workload on a '
      'provider whose container execution is mediated.',
    );
  }
}

/// Launch compatibility for every configured provider, and the deployment's
/// live credential gate.
///
/// The per-provider records are built once from the resolved deployment
/// configuration; the optional [ProviderCredentialGate] is consulted per
/// verdict because credential state changes under a running process. Both
/// launch surfaces and operator diagnostics consume this one object, so no
/// entry point re-derives compatibility — or admissibility — locally.
final class ProviderExecutionInventory {
  /// Creates an inventory over per-provider [supports], keyed by provider ID,
  /// consulting [credentialGate] before admitting any supported combination.
  new(Map<String, ProviderExecutionSupport> supports, {ProviderCredentialGate? credentialGate})
    : _supports = Map.unmodifiable(supports),
      _credentialGate = credentialGate;

  /// Builds the inventory for a deployment.
  ///
  /// Every ID in [acpProviderIds] is an ACP registration. Of the remaining
  /// [providerIds], only those resolving to a built-in provider family are
  /// recorded: an unrecognized alias gets no entry at all, so the inventory
  /// never claims mediation for an adapter it cannot name. Harness
  /// construction still rejects it by identity. Both sets are normalized to
  /// canonical provider identity, so lookups match however a caller spelled
  /// the ID.
  factory of({
    required Iterable<String> providerIds,
    required Set<String> acpProviderIds,
    ProviderCredentialGate? credentialGate,
  }) {
    const builtInFamilies = {ProviderIdentity.claude, ProviderIdentity.codex};
    final acp = acpProviderIds.map(ProviderIdentity.normalize).toSet();
    return ProviderExecutionInventory({
      for (final providerId in {...providerIds.map(ProviderIdentity.normalize), ...acp})
        if (acp.contains(providerId))
          providerId: ProviderExecutionSupport.acp(providerId)
        else if (builtInFamilies.contains(ProviderIdentity.family(providerId)))
          providerId: ProviderExecutionSupport.builtIn(providerId),
    }, credentialGate: credentialGate);
  }

  final Map<String, ProviderExecutionSupport> _supports;
  final ProviderCredentialGate? _credentialGate;

  /// Compatibility records keyed by provider ID.
  Map<String, ProviderExecutionSupport> get supports => _supports;

  /// Returns the verdict for launching [providerId] on [surface] under [policy].
  ///
  /// A provider with no record is reported as supported for the *surface*: an
  /// unregistered provider identity is rejected by harness construction, and
  /// inventing a second rejection here would mask that error. The credential
  /// gate is consulted regardless, because a provider alias resolving to a
  /// built-in family carries no record — which is exactly the shape a forced
  /// `providers.<id>.auth` on an alias takes.
  ProviderExecutionVerdict verdictFor({
    required String providerId,
    required ProviderLaunchSurface surface,
    required ExecutionPolicy policy,
  }) {
    final support = _supports[ProviderIdentity.normalize(providerId)];
    final verdict = support?.verdictFor(surface: surface, policy: policy) ?? const ProviderExecutionVerdict.supported();
    if (!verdict.isSupported) return verdict;
    final refusal = _credentialGate?.call(providerId);
    return refusal == null ? verdict : ProviderExecutionVerdict.credentialUnavailable(refusal);
  }
}

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
String? acpContainerRequirementError(String providerId, AcpAgentConfig agent) {
  final isDirect = agent.topology == AcpAgentTopology.direct;
  if (isDirect && !agent.containerIsolationRequired) return null;
  final path = isDirect ? 'container_isolation_required' : 'topology';
  return 'Invalid harness.acp.agents.$providerId.$path: DartClaw provides no $_acpContainerMediationGap, so an ACP '
      'registration that requires a container boundary has no runnable execution. Remove the registration, or — if '
      'you have established that this agent is safe to run directly on the host — declare it with topology: direct '
      'and container_isolation_required: false. DartClaw validates that declaration only when the registration also '
      'sets requires_guard_mediation: true.';
}
