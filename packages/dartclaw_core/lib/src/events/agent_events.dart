part of 'dartclaw_event.dart';

/// Intermediate sealed type for agent observer events.
sealed class AgentLifecycleEvent extends DartclawEvent {
  /// Runner identifier associated with the event.
  int get runnerId;

  @override
  /// Timestamp when the agent event occurred.
  DateTime get timestamp;
}

/// Fired when a runner transitions between states (idle/busy/stopped/crashed).
// NOT_ALERTABLE: worker lifecycle telemetry — surfaced via SSE only
final class AgentStateChangedEvent extends AgentLifecycleEvent {
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

  /// Creates an agent-state-changed event.
  AgentStateChangedEvent({required this.runnerId, required this.state, this.currentTaskId, required this.timestamp});

  @override
  String toString() => 'AgentStateChangedEvent(runner: $runnerId, state: $state, task: $currentTaskId)';
}
