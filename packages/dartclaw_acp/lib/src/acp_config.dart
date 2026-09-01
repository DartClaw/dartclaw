import 'package:collection/collection.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

const _acpAgentsEquality = MapEquality<String, AcpAgentConfig>();
const _stringListEquality = ListEquality<String>();

/// Verified ACP target metadata used by config validation and probes.
class AcpVerifiedTargetProfile {
  /// Provider identity for this ACP target.
  final String providerId;

  /// Default ACP binary.
  final String binary;

  /// Default ACP arguments.
  final List<String> args;

  /// Required provider builtins/extensions.
  final List<String> requiredBuiltins;

  /// Known ACP relay selectors that cannot prove direct guard mediation.
  final Set<String> knownRelaySelectors;

  /// Default direct model provider proof selector.
  final String? modelProvider;

  /// Verification evidence key.
  final String verification;

  /// Whether `fs` capability advertisement is required for reverse-call proof.
  final bool requiresFsCapability;

  /// Whether `terminal` capability advertisement is required for reverse-call proof.
  final bool requiresTerminalCapability;

  /// Creates verified target metadata.
  const new({
    required this.providerId,
    required this.binary,
    required this.args,
    required this.requiredBuiltins,
    required this.knownRelaySelectors,
    required this.modelProvider,
    required this.verification,
    this.requiresFsCapability = false,
    this.requiresTerminalCapability = false,
  });

  /// Metadata for the verified Goose ACP target.
  static const goose = AcpVerifiedTargetProfile(
    providerId: 'goose',
    binary: 'goose',
    args: ['acp', '--with-builtin', 'developer'],
    requiredBuiltins: ['developer'],
    knownRelaySelectors: {'claude-acp', 'codex-acp'},
    modelProvider: null,
    verification: 'a0_1_goose_direct',
    requiresTerminalCapability: true,
  );

  /// Metadata for the verified Mistral Vibe ACP target.
  static const vibe = AcpVerifiedTargetProfile(
    providerId: 'vibe',
    binary: 'vibe-acp',
    args: [],
    requiredBuiltins: [],
    knownRelaySelectors: {},
    modelProvider: 'mistral',
    verification: 'vibe_acp_direct_probe',
    requiresFsCapability: true,
  );

  /// Verified ACP target profiles keyed by provider identity.
  static const byProviderId = {'goose': goose, 'vibe': vibe};
}

/// ACP agent registration section.
class AcpConfig {
  /// Registered ACP agents keyed by provider ID.
  final Map<String, AcpAgentConfig> agents;

  /// Creates an ACP registration section.
  const new({this.agents = const {}});

  /// Default ACP registration section.
  const new defaults() : this();

  /// Returns the ACP agent registration for [providerId], if configured.
  AcpAgentConfig? operator [](String providerId) {
    if (providerId.trim().isEmpty) return null;
    final normalized = ProviderIdentity.normalize(providerId);
    AcpAgentConfig? match;
    for (final entry in agents.entries) {
      if (entry.key.trim().isEmpty) continue;
      if (ProviderIdentity.normalize(entry.key) != normalized) continue;
      if (match != null) {
        throw StateError('Configured ACP provider IDs collide after normalization to "$normalized"');
      }
      match = entry.value;
    }
    return match;
  }

  /// Whether no ACP agents are registered.
  bool get isEmpty => agents.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AcpConfig && _acpAgentsEquality.equals(agents, other.agents);

  @override
  int get hashCode => _acpAgentsEquality.hash(agents);

  @override
  String toString() => 'AcpConfig(agents: $agents)';
}

/// Topology declared by an ACP agent registration.
enum AcpAgentTopology {
  /// Direct model-provider topology eligible for verified guard mediation.
  direct,

  /// Relay-provider topology; claims no guard mediation, so a container is
  /// its only possible boundary.
  relay,

  /// Unverified topology; treated like [relay] until verification proves
  /// reverse-call mediation.
  unverified,
}

/// Container profile required by an unguarded relay/unverified ACP agent.
enum AcpContainerProfile {
  /// Restricted container profile.
  restricted,

  /// Workspace-write container profile.
  workspace,
}

/// Security posture derived from an ACP agent registration.
enum AcpSecurityClassification {
  /// Verified direct-provider configuration may claim guard mediation.
  guardMediated,

  /// Configuration claiming no guard mediation. ACP has no mediated container
  /// execution, so every registration that reaches a turn runs on the host.
  hostOnly,
}

/// Immutable config for one ACP agent registration.
class AcpAgentConfig {
  /// ACP agent binary path or executable name.
  final String binary;

  /// Arguments passed to the ACP agent binary.
  final List<String> args;

  /// Declared ACP topology.
  final AcpAgentTopology topology;

  /// Direct model provider selector, when declared.
  final String? modelProvider;

  /// Verification evidence key for guard-mediated direct-provider claims.
  final String? verification;

  /// Whether this registration claims guard mediation.
  final bool requiresGuardMediation;

  /// Required provider builtins/extensions.
  final List<String> requiredBuiltins;

  /// Whether a container boundary is required before spawn.
  final bool containerIsolationRequired;

  /// Required container profile for relay/unverified agents.
  final AcpContainerProfile? containerProfile;

  /// Name of the `credentials.<name>` API-key entry presented to this agent, or
  /// `null` when the agent authenticates itself.
  ///
  /// The only path by which a DartClaw-managed credential reaches an ACP spawn:
  /// nothing is presented implicitly, and a subscription credential is never
  /// presented at all.
  final String? credential;

  /// Creates an ACP agent registration.
  const new({
    required this.binary,
    this.args = const [],
    this.topology = AcpAgentTopology.unverified,
    this.modelProvider,
    this.verification,
    this.requiresGuardMediation = false,
    this.requiredBuiltins = const [],
    this.containerIsolationRequired = false,
    this.containerProfile,
    this.credential,
  });

  /// Derived security classification.
  AcpSecurityClassification get securityClassification =>
      requiresGuardMediation ? AcpSecurityClassification.guardMediated : AcpSecurityClassification.hostOnly;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpAgentConfig &&
          binary == other.binary &&
          _stringListEquality.equals(args, other.args) &&
          topology == other.topology &&
          modelProvider == other.modelProvider &&
          verification == other.verification &&
          requiresGuardMediation == other.requiresGuardMediation &&
          _stringListEquality.equals(requiredBuiltins, other.requiredBuiltins) &&
          containerIsolationRequired == other.containerIsolationRequired &&
          containerProfile == other.containerProfile &&
          credential == other.credential;

  @override
  int get hashCode => Object.hash(
    binary,
    _stringListEquality.hash(args),
    topology,
    modelProvider,
    verification,
    requiresGuardMediation,
    _stringListEquality.hash(requiredBuiltins),
    containerIsolationRequired,
    containerProfile,
    credential,
  );

  @override
  String toString() =>
      'AcpAgentConfig(binary: $binary, args: $args, topology: $topology, modelProvider: $modelProvider, '
      'verification: $verification, requiresGuardMediation: $requiresGuardMediation, '
      'requiredBuiltins: $requiredBuiltins, containerIsolationRequired: $containerIsolationRequired, '
      'containerProfile: $containerProfile, credential: $credential)';
}
