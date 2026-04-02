part of 'governance_config.dart';

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

/// Loop detection configuration.
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
