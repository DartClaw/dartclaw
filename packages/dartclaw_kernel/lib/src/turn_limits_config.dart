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

/// Turn wall-clock and liveness limits.
class TurnLimitsConfig {
  /// Default progress-silence window for provider turns.
  static const defaultStallTimeout = Duration(minutes: 5);

  /// Default wall-clock ceiling for provider turns.
  static const defaultTurnTimeout = Duration(minutes: 30);

  /// Maximum silent period before the turn is considered stalled.
  final Duration stallTimeout;

  /// Action to take when the timeout elapses.
  final TurnProgressAction stallAction;

  /// Wall-clock ceiling for provider turns.
  final Duration turnTimeout;

  /// Whether turn-progress monitoring is active.
  bool get enabled => stallTimeout > Duration.zero;

  /// Creates turn-progress settings.
  const new({
    this.stallTimeout = defaultStallTimeout,
    this.stallAction = TurnProgressAction.cancel,
    this.turnTimeout = defaultTurnTimeout,
  });

  /// Creates a [TurnLimitsConfig.defaults] value.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnLimitsConfig &&
          stallTimeout == other.stallTimeout &&
          stallAction == other.stallAction &&
          turnTimeout == other.turnTimeout;

  @override
  int get hashCode => Object.hash(stallTimeout, stallAction, turnTimeout);

  @override
  String toString() =>
      'TurnLimitsConfig(stallTimeout: $stallTimeout, stallAction: $stallAction, turnTimeout: $turnTimeout)';
}
