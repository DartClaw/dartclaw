import 'package:collection/collection.dart';

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
  const AcpVerifiedTargetProfile({
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
    requiresTerminalCapability: true,
  );

  /// Verified ACP target profiles keyed by provider identity.
  static const byProviderId = {'goose': goose, 'vibe': vibe};
}

/// Harness-level runtime controls.
class HarnessConfig {
  /// Waiting/stuck turn monitor thresholds.
  final TurnMonitorConfig turnMonitor;

  /// ACP agent registrations keyed by provider identity.
  final AcpConfig acp;

  /// Creates harness-level runtime controls.
  const HarnessConfig({this.turnMonitor = const TurnMonitorConfig.defaults(), this.acp = const AcpConfig.defaults()});

  /// Default harness controls.
  const HarnessConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is HarnessConfig && turnMonitor == other.turnMonitor && acp == other.acp;

  @override
  int get hashCode => Object.hash(turnMonitor, acp);

  @override
  String toString() => 'HarnessConfig(turnMonitor: $turnMonitor, acp: $acp)';
}

/// Thresholds for surfacing active turn waits as operator-visible `waiting` and
/// `stuck` states.
///
/// Both thresholds must be positive durations with `waitWarningAfter <=
/// stuckAfter`, and `stuckAfter` must be below the provider turn global timeout
/// (`worker_timeout`). Invalid values fall back to the defaults during parsing.
/// The thresholds are restart-required unless routed through live config.
class TurnMonitorConfig {
  /// Duration before lock wait state is operator-visible as `waiting`.
  final Duration waitWarningAfter;

  /// Duration before a waiting turn is operator-visible as `stuck`.
  final Duration stuckAfter;

  /// Creates turn monitor thresholds.
  const TurnMonitorConfig({
    this.waitWarningAfter = const Duration(seconds: 30),
    this.stuckAfter = const Duration(seconds: 120),
  });

  /// Default turn monitor thresholds.
  const TurnMonitorConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnMonitorConfig && waitWarningAfter == other.waitWarningAfter && stuckAfter == other.stuckAfter;

  @override
  int get hashCode => Object.hash(waitWarningAfter, stuckAfter);

  @override
  String toString() => 'TurnMonitorConfig(waitWarningAfter: $waitWarningAfter, stuckAfter: $stuckAfter)';
}

/// ACP agent registration section.
class AcpConfig {
  /// Registered ACP agents keyed by provider ID.
  final Map<String, AcpAgentConfig> agents;

  /// Creates an ACP registration section.
  const AcpConfig({this.agents = const {}});

  /// Default ACP registration section.
  const AcpConfig.defaults() : this();

  /// Returns the ACP agent registration for [providerId], if configured.
  AcpAgentConfig? operator [](String providerId) => agents[providerId];

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

  /// Relay-provider topology; container-isolation-only in S03.
  relay,

  /// Unverified topology; container-isolation-only in S03.
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

  /// Relay/unverified configuration must run inside an enforced container boundary.
  containerIsolationOnly,
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

  /// Creates an ACP agent registration.
  const AcpAgentConfig({
    required this.binary,
    this.args = const [],
    this.topology = AcpAgentTopology.unverified,
    this.modelProvider,
    this.verification,
    this.requiresGuardMediation = false,
    this.requiredBuiltins = const [],
    this.containerIsolationRequired = false,
    this.containerProfile,
  });

  /// Derived security classification.
  AcpSecurityClassification get securityClassification => requiresGuardMediation
      ? AcpSecurityClassification.guardMediated
      : AcpSecurityClassification.containerIsolationOnly;

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
          containerProfile == other.containerProfile;

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
  );

  @override
  String toString() =>
      'AcpAgentConfig(binary: $binary, args: $args, topology: $topology, modelProvider: $modelProvider, '
      'verification: $verification, requiresGuardMediation: $requiresGuardMediation, '
      'requiredBuiltins: $requiredBuiltins, containerIsolationRequired: $containerIsolationRequired, '
      'containerProfile: $containerProfile)';
}
