part of 'dartclaw_event.dart';

/// Intermediate sealed type for agent-execution lifecycle events.
sealed class AgentExecutionEvent extends DartclawEvent {
  /// Identifier of the execution associated with the event.
  String get agentExecutionId;

  @override
  DateTime get timestamp;
}

/// Fired when an agent execution changes lifecycle status.
final class AgentExecutionStatusChangedEvent extends AgentExecutionEvent {
  @override
  final String agentExecutionId;

  /// Previous execution status before the transition.
  final String oldStatus;

  /// New execution status after the transition.
  final String newStatus;

  /// Trigger or subsystem that initiated the transition.
  final String trigger;

  @override
  final DateTime timestamp;

  /// Creates an agent-execution-status-changed event.
  AgentExecutionStatusChangedEvent({
    required this.agentExecutionId,
    required this.oldStatus,
    required this.newStatus,
    required this.trigger,
    required this.timestamp,
  });

  @override
  String toString() =>
      'AgentExecutionStatusChangedEvent(agentExecution: $agentExecutionId, '
      '$oldStatus -> $newStatus, trigger: $trigger)';
}
