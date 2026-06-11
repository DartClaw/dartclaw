import 'package:collection/collection.dart';

const _delegationAgentsEquality = ListEquality<DelegationAgentConfig>();

/// Delegation budget accounting mode.
enum DelegationBudgetAccounting {
  /// Use only provider-reported usage.
  providerReported,

  /// Estimate usage from streamed output when the provider does not report it.
  estimateIfUnreported,
}

/// Allowlisted provider identity for `delegate_to_agent`.
class DelegationAgentConfig {
  /// Provider identity, e.g. `goose` or `codex`.
  final String id;

  /// Whether this delegation requires reverse-call guard mediation.
  final bool requireGuardMediation;

  /// Whether this agent may only report budget after completion.
  final bool postRunAccountingOnly;

  /// Creates an allowlisted delegation agent.
  const DelegationAgentConfig({
    required this.id,
    this.requireGuardMediation = false,
    this.postRunAccountingOnly = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DelegationAgentConfig &&
          id == other.id &&
          requireGuardMediation == other.requireGuardMediation &&
          postRunAccountingOnly == other.postRunAccountingOnly;

  @override
  int get hashCode => Object.hash(id, requireGuardMediation, postRunAccountingOnly);

  @override
  String toString() =>
      'DelegationAgentConfig(id: $id, requireGuardMediation: $requireGuardMediation, '
      'postRunAccountingOnly: $postRunAccountingOnly)';
}

/// Rate limit for delegation MCP tool calls.
class DelegationRateLimitConfig {
  /// Maximum delegations per minute. `0` disables limiting.
  final int maxPerMinute;

  /// Creates a delegation rate-limit config.
  const DelegationRateLimitConfig({this.maxPerMinute = 0});

  /// Default delegation rate-limit config.
  const DelegationRateLimitConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DelegationRateLimitConfig && maxPerMinute == other.maxPerMinute;

  @override
  int get hashCode => maxPerMinute.hashCode;

  @override
  String toString() => 'DelegationRateLimitConfig(maxPerMinute: $maxPerMinute)';
}

/// Configuration for the internal `delegate_to_agent` MCP tool.
class DelegationConfig {
  /// Whether delegation is enabled.
  final bool enabled;

  /// Allowlisted provider identities.
  final List<DelegationAgentConfig> agents;

  /// Per-delegation token cap. `0` means no cap.
  final int maxBudgetTokens;

  /// Budget accounting mode for strict enforcement.
  final DelegationBudgetAccounting budgetAccounting;

  /// Delegation invocation rate limit.
  final DelegationRateLimitConfig rateLimit;

  /// Creates delegation configuration.
  const DelegationConfig({
    this.enabled = false,
    this.agents = const [],
    this.maxBudgetTokens = 0,
    this.budgetAccounting = DelegationBudgetAccounting.providerReported,
    this.rateLimit = const DelegationRateLimitConfig.defaults(),
  });

  /// Default disabled delegation configuration.
  const DelegationConfig.defaults() : this();

  /// Returns the allowlist entry for [id], if present.
  DelegationAgentConfig? agent(String id) {
    for (final agent in agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DelegationConfig &&
          enabled == other.enabled &&
          _delegationAgentsEquality.equals(agents, other.agents) &&
          maxBudgetTokens == other.maxBudgetTokens &&
          budgetAccounting == other.budgetAccounting &&
          rateLimit == other.rateLimit;

  @override
  int get hashCode =>
      Object.hash(enabled, _delegationAgentsEquality.hash(agents), maxBudgetTokens, budgetAccounting, rateLimit);

  @override
  String toString() =>
      'DelegationConfig(enabled: $enabled, agents: $agents, maxBudgetTokens: $maxBudgetTokens, '
      'budgetAccounting: $budgetAccounting, rateLimit: $rateLimit)';
}
