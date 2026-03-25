/// Governance configuration for DartClaw runtime.
///
/// Controls rate limiting, budget enforcement, and loop detection.
/// Parsed from the `governance:` YAML section. All sub-sections are
/// disabled by default (0 = disabled convention).
library;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Action to take when the token budget is exceeded.
enum BudgetAction {
  /// Log a warning but continue processing.
  warn,

  /// Block new turns until the next budget window.
  block;

  /// Parses a YAML string to [BudgetAction].
  ///
  /// Returns `null` for unknown values.
  static BudgetAction? fromYaml(String value) => switch (value) {
    'warn' => BudgetAction.warn,
    'block' => BudgetAction.block,
    _ => null,
  };

  /// Returns the YAML representation.
  String toYaml() => name;
}

/// Action to take when a loop is detected.
enum LoopAction {
  /// Abort the current turn and notify the user.
  abort,

  /// Log a warning and continue.
  warn;

  /// Parses a YAML string to [LoopAction].
  ///
  /// Returns `null` for unknown values.
  static LoopAction? fromYaml(String value) => switch (value) {
    'abort' => LoopAction.abort,
    'warn' => LoopAction.warn,
    _ => null,
  };

  /// Returns the YAML representation.
  String toYaml() => name;
}

/// Strategy for draining queued messages within a session.
enum QueueStrategy {
  /// Preserve existing FIFO behavior.
  fifo,

  /// Drain queued messages in round-robin order across senders.
  fair;

  static QueueStrategy? fromYaml(String value) => switch (value) {
    'fifo' => QueueStrategy.fifo,
    'fair' => QueueStrategy.fair,
    _ => null,
  };

  String toYaml() => name;
}

// ---------------------------------------------------------------------------
// Sub-config classes
// ---------------------------------------------------------------------------

/// Per-sender inbound message rate limit configuration.
class PerSenderRateLimitConfig {
  /// Maximum messages allowed per sender within [windowMinutes]. 0 = disabled.
  final int messages;

  /// Sliding window duration in minutes.
  final int windowMinutes;

  /// Maximum queued entries per sender in a session queue. 0 = disabled.
  final int maxQueued;

  /// Maximum queued entries per sender while paused. 0 = disabled.
  final int maxPauseQueued;

  /// Whether inbound rate limiting is active (messages > 0 and windowMinutes > 0).
  bool get enabled => messages > 0 && windowMinutes > 0;

  const PerSenderRateLimitConfig({
    this.messages = 0,
    this.windowMinutes = 5,
    this.maxQueued = 0,
    this.maxPauseQueued = 0,
  });

  const PerSenderRateLimitConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerSenderRateLimitConfig &&
          messages == other.messages &&
          windowMinutes == other.windowMinutes &&
          maxQueued == other.maxQueued &&
          maxPauseQueued == other.maxPauseQueued;

  @override
  int get hashCode => Object.hash(messages, windowMinutes, maxQueued, maxPauseQueued);

  @override
  String toString() =>
      'PerSenderRateLimitConfig(messages: $messages, windowMinutes: $windowMinutes, '
      'maxQueued: $maxQueued, maxPauseQueued: $maxPauseQueued)';
}

/// Global turn rate limit configuration.
class GlobalRateLimitConfig {
  /// Maximum turns allowed globally within [windowMinutes]. 0 = disabled.
  final int turns;

  /// Sliding window duration in minutes.
  final int windowMinutes;

  /// Whether rate limiting is active (turns > 0 and windowMinutes > 0).
  bool get enabled => turns > 0 && windowMinutes > 0;

  const GlobalRateLimitConfig({this.turns = 0, this.windowMinutes = 60});

  const GlobalRateLimitConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlobalRateLimitConfig && turns == other.turns && windowMinutes == other.windowMinutes;

  @override
  int get hashCode => Object.hash(turns, windowMinutes);

  @override
  String toString() => 'GlobalRateLimitConfig(turns: $turns, windowMinutes: $windowMinutes)';
}

/// Container for per-sender and global rate limit configs.
class RateLimitsConfig {
  final PerSenderRateLimitConfig perSender;
  final GlobalRateLimitConfig global;

  const RateLimitsConfig({
    this.perSender = const PerSenderRateLimitConfig.defaults(),
    this.global = const GlobalRateLimitConfig.defaults(),
  });

  const RateLimitsConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RateLimitsConfig && perSender == other.perSender && global == other.global;

  @override
  int get hashCode => Object.hash(perSender, global);

  @override
  String toString() => 'RateLimitsConfig(perSender: $perSender, global: $global)';
}

/// Token budget configuration. Parsed but not enforced until S09.
class BudgetConfig {
  /// Maximum daily token usage. 0 = disabled.
  final int dailyTokens;

  /// Action when budget is exceeded.
  final BudgetAction action;

  /// Timezone for daily budget window reset (IANA name, e.g. 'UTC', 'America/New_York').
  final String timezone;

  /// Whether budget enforcement is active (dailyTokens > 0).
  bool get enabled => dailyTokens > 0;

  const BudgetConfig({this.dailyTokens = 0, this.action = BudgetAction.warn, this.timezone = 'UTC'});

  const BudgetConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BudgetConfig && dailyTokens == other.dailyTokens && action == other.action && timezone == other.timezone;

  @override
  int get hashCode => Object.hash(dailyTokens, action, timezone);

  @override
  String toString() => 'BudgetConfig(dailyTokens: $dailyTokens, action: $action, timezone: $timezone)';
}

/// Loop detection configuration. Parsed but not enforced until S10.
class LoopDetectionConfig {
  /// Whether loop detection is active.
  final bool enabled;

  /// Maximum consecutive turns before triggering loop detection. 0 = disabled.
  final int maxConsecutiveTurns;

  /// Maximum tokens per minute before triggering velocity-based detection. 0 = disabled.
  final int maxTokensPerMinute;

  /// Sliding window for velocity tracking in minutes.
  final int velocityWindowMinutes;

  /// Maximum consecutive identical tool calls before triggering. 0 = disabled.
  final int maxConsecutiveIdenticalToolCalls;

  /// Action to take when a loop is detected.
  final LoopAction action;

  const LoopDetectionConfig({
    this.enabled = false,
    this.maxConsecutiveTurns = 0,
    this.maxTokensPerMinute = 0,
    this.velocityWindowMinutes = 5,
    this.maxConsecutiveIdenticalToolCalls = 0,
    this.action = LoopAction.abort,
  });

  const LoopDetectionConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoopDetectionConfig &&
          enabled == other.enabled &&
          maxConsecutiveTurns == other.maxConsecutiveTurns &&
          maxTokensPerMinute == other.maxTokensPerMinute &&
          velocityWindowMinutes == other.velocityWindowMinutes &&
          maxConsecutiveIdenticalToolCalls == other.maxConsecutiveIdenticalToolCalls &&
          action == other.action;

  @override
  int get hashCode => Object.hash(
    enabled,
    maxConsecutiveTurns,
    maxTokensPerMinute,
    velocityWindowMinutes,
    maxConsecutiveIdenticalToolCalls,
    action,
  );

  @override
  String toString() =>
      'LoopDetectionConfig(enabled: $enabled, maxConsecutiveTurns: $maxConsecutiveTurns, '
      'maxTokensPerMinute: $maxTokensPerMinute, velocityWindowMinutes: $velocityWindowMinutes, '
      'maxConsecutiveIdenticalToolCalls: $maxConsecutiveIdenticalToolCalls, action: $action)';
}

/// Crowd coding model/effort defaults applied to channel-routed group sessions.
class CrowdCodingConfig {
  /// Default model override for crowd coding turns, or `null` to use the global default.
  final String? model;

  /// Default reasoning effort override for crowd coding turns, or `null` to use the global default.
  final String? effort;

  const CrowdCodingConfig({this.model, this.effort});

  const CrowdCodingConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CrowdCodingConfig && model == other.model && effort == other.effort;

  @override
  int get hashCode => Object.hash(model, effort);

  @override
  String toString() => 'CrowdCodingConfig(model: $model, effort: $effort)';
}

// ---------------------------------------------------------------------------
// Top-level config
// ---------------------------------------------------------------------------

/// Top-level governance configuration.
///
/// Rate limiting is enforced in S08. Budget ([budget]) and loop detection
/// ([loopDetection]) sections are parsed here for schema completeness but
/// their enforcement is implemented in S09 and S10 respectively.
class GovernanceConfig {
  /// Sender IDs that are exempt from all per-sender rate limits.
  ///
  /// An empty list means ALL senders are treated as admins (no per-sender
  /// restrictions). This is the default, suitable for single-user deployments.
  final List<String> adminSenders;

  /// Rate limit configuration (per-sender and global).
  final RateLimitsConfig rateLimits;

  /// Token budget configuration. Enforced in S09.
  final BudgetConfig budget;

  /// Loop detection configuration. Enforced in S10.
  final LoopDetectionConfig loopDetection;

  /// Queue drain strategy for per-session message queues.
  final QueueStrategy queueStrategy;

  /// Crowd coding model/effort defaults for channel-routed group sessions.
  final CrowdCodingConfig crowdCoding;

  const GovernanceConfig({
    this.adminSenders = const [],
    this.rateLimits = const RateLimitsConfig.defaults(),
    this.budget = const BudgetConfig.defaults(),
    this.loopDetection = const LoopDetectionConfig.defaults(),
    this.queueStrategy = QueueStrategy.fifo,
    this.crowdCoding = const CrowdCodingConfig.defaults(),
  });

  /// Default governance config — all features disabled, all senders are admins.
  const GovernanceConfig.defaults() : this();

  /// Returns `true` if [senderId] is an admin.
  ///
  /// When [adminSenders] is empty, all senders are considered admins (suitable
  /// for single-user deployments). When non-empty, only listed IDs are admins.
  bool isAdmin(String senderId) {
    if (adminSenders.isEmpty) return true;
    return adminSenders.contains(senderId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GovernanceConfig &&
          _listEquals(adminSenders, other.adminSenders) &&
          rateLimits == other.rateLimits &&
          budget == other.budget &&
          loopDetection == other.loopDetection &&
          queueStrategy == other.queueStrategy &&
          crowdCoding == other.crowdCoding;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(adminSenders), rateLimits, budget, loopDetection, queueStrategy, crowdCoding);

  @override
  String toString() =>
      'GovernanceConfig(adminSenders: $adminSenders, rateLimits: $rateLimits, '
      'budget: $budget, loopDetection: $loopDetection, queueStrategy: $queueStrategy, '
      'crowdCoding: $crowdCoding)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
