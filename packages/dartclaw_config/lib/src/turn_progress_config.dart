part of 'governance_config.dart';

/// Action to take when a turn stops emitting progress events.
enum TurnProgressAction {
  /// Log and surface the stall, but keep the turn running.
  warn,

  /// Cancel the active turn when the stall timeout is reached.
  cancel,

  /// Ignore stalls entirely after detection.
  ignore;

  static TurnProgressAction? fromYaml(String value) => switch (value) {
    'warn' => TurnProgressAction.warn,
    'cancel' => TurnProgressAction.cancel,
    'ignore' => TurnProgressAction.ignore,
    _ => null,
  };

  String toYaml() => name;
}

/// Progress-aware turn stall detection config.
class TurnProgressConfig {
  /// Maximum silent period before the turn is considered stalled.
  final Duration stallTimeout;

  /// Action to take when the timeout elapses.
  final TurnProgressAction stallAction;

  /// Whether turn-progress monitoring is active.
  bool get enabled => stallTimeout > Duration.zero;

  const TurnProgressConfig({this.stallTimeout = Duration.zero, this.stallAction = TurnProgressAction.warn});

  const TurnProgressConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnProgressConfig && stallTimeout == other.stallTimeout && stallAction == other.stallAction;

  @override
  int get hashCode => Object.hash(stallTimeout, stallAction);

  @override
  String toString() => 'TurnProgressConfig(stallTimeout: $stallTimeout, stallAction: $stallAction)';
}
