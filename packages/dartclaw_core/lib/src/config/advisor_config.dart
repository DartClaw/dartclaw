/// Configuration for the advisor agent subsystem.
class AdvisorConfig {
  /// Whether the advisor subscriber is enabled.
  final bool enabled;

  /// Optional model override for advisor turns.
  final String? model;

  /// Optional effort override for advisor turns.
  final String? effort;

  /// Active advisor trigger names.
  final List<String> triggers;

  /// Periodic trigger interval in minutes.
  final int periodicIntervalMinutes;

  /// Maximum normalized event entries retained in the context window.
  final int maxWindowTurns;

  /// Maximum prior advisor reflections retained for prompting.
  final int maxPriorReflections;

  const AdvisorConfig({
    this.enabled = false,
    this.model,
    this.effort,
    this.triggers = const [],
    this.periodicIntervalMinutes = 10,
    this.maxWindowTurns = 10,
    this.maxPriorReflections = 3,
  });

  const AdvisorConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdvisorConfig &&
          enabled == other.enabled &&
          model == other.model &&
          effort == other.effort &&
          _listEquals(triggers, other.triggers) &&
          periodicIntervalMinutes == other.periodicIntervalMinutes &&
          maxWindowTurns == other.maxWindowTurns &&
          maxPriorReflections == other.maxPriorReflections;

  @override
  int get hashCode => Object.hash(
    enabled,
    model,
    effort,
    Object.hashAll(triggers),
    periodicIntervalMinutes,
    maxWindowTurns,
    maxPriorReflections,
  );

  @override
  String toString() =>
      'AdvisorConfig(enabled: $enabled, model: $model, effort: $effort, '
      'triggers: $triggers, periodicIntervalMinutes: $periodicIntervalMinutes, '
      'maxWindowTurns: $maxWindowTurns, maxPriorReflections: $maxPriorReflections)';

  static bool _listEquals(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}
