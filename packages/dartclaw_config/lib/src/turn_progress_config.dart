part of 'governance_config.dart';

/// Action to take when a turn stops emitting progress events.
enum TurnProgressAction {
  /// Log and surface the stall, but keep the turn running.
  warn,

  /// Cancel the active turn when the stall timeout is reached.
  cancel,

  /// Ignore stalls entirely after detection.
  ignore;

  /// Parses a [TurnProgressAction] from its YAML string representation.
  static TurnProgressAction? fromYaml(String value) => switch (value) {
    'warn' => TurnProgressAction.warn,
    'cancel' => TurnProgressAction.cancel,
    'ignore' => TurnProgressAction.ignore,
    _ => null,
  };

  /// String toYaml() => name;.
  String toYaml() => name;
}

/// Progress-aware turn stall detection config.
class TurnProgressConfig {
  /// Default stdout silence window for one-shot workflow CLI steps.
  static const defaultStallTimeout = Duration(minutes: 5);

  /// Default wall-clock ceiling for one-shot workflow CLI steps.
  static const defaultMaxDuration = Duration(minutes: 30);

  /// Maximum silent period before the turn is considered stalled.
  final Duration stallTimeout;

  /// Action to take when the timeout elapses.
  final TurnProgressAction stallAction;

  /// Wall-clock ceiling for one-shot workflow CLI steps.
  final Duration maxDuration;

  /// Whether turn-progress monitoring is active.
  bool get enabled => stallTimeout > Duration.zero;

  /// Creates turn-progress settings.
  const TurnProgressConfig({
    this.stallTimeout = defaultStallTimeout,
    this.stallAction = TurnProgressAction.cancel,
    this.maxDuration = defaultMaxDuration,
  });

  /// Creates a [TurnProgressConfig.defaults] value.
  const TurnProgressConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnProgressConfig &&
          stallTimeout == other.stallTimeout &&
          stallAction == other.stallAction &&
          maxDuration == other.maxDuration;

  @override
  int get hashCode => Object.hash(stallTimeout, stallAction, maxDuration);

  @override
  String toString() =>
      'TurnProgressConfig(stallTimeout: $stallTimeout, stallAction: $stallAction, maxDuration: $maxDuration)';
}
