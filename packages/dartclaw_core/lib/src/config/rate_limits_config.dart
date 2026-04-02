part of 'governance_config.dart';

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
