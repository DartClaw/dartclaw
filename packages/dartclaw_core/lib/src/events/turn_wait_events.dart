part of 'dartclaw_event.dart';

/// Operator-visible wait/stuck state for an active session turn.
final class TurnWaitStateChangedEvent extends DartclawEvent {
  final String sessionId;
  final String turnId;
  final String? taskId;
  final String state;
  final String waitReason;
  final DateTime? waitingSince;
  final DateTime? stuckSince;
  final DateTime? globalTimeoutAt;
  final bool canCancel;
  @override
  final DateTime timestamp;

  TurnWaitStateChangedEvent({
    required this.sessionId,
    required this.turnId,
    required this.state,
    required this.waitReason,
    required this.canCancel,
    required this.timestamp,
    this.waitingSince,
    this.stuckSince,
    this.globalTimeoutAt,
    this.taskId,
  });

  @override
  String toString() => 'TurnWaitStateChangedEvent(session: $sessionId, turn: $turnId, state: $state)';
}
