part of 'dartclaw_event.dart';

/// Intermediate sealed type for harness-runner lifecycle events.
sealed class RunnerLifecycleEvent extends DartclawEvent {
  /// Runner identifier associated with the event.
  int get runnerId;

  @override
  /// Timestamp when the runner event occurred.
  DateTime get timestamp;
}

/// Fired when a runner transitions between states (idle/busy/stopped/crashed).
// NOT_ALERTABLE: worker lifecycle telemetry — surfaced via SSE only
final class RunnerStateChangedEvent extends RunnerLifecycleEvent {
  @override
  /// Runner identifier whose state changed.
  final int runnerId;

  /// New runner state label such as `idle`, `busy`, or `stopped`.
  final String state;

  /// Current task id assigned to the runner, if any.
  final String? currentTaskId;

  @override
  /// Timestamp when the state change occurred.
  final DateTime timestamp;

  /// Creates a runner-state-changed event.
  new({required this.runnerId, required this.state, this.currentTaskId, required this.timestamp});

  @override
  String toString() => 'RunnerStateChangedEvent(runner: $runnerId, state: $state, task: $currentTaskId)';
}
