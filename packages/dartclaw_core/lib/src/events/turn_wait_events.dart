part of 'dartclaw_event.dart';

/// Lifecycle/wait phase of a session turn. Serialized to the wire via `.name`;
/// the value names are the frozen wire contract at the server API/SSE boundary.
enum TurnWaitState { idle, running, waiting, stuck, cancelling, cancelled, completed, failed }

/// Why a turn is waiting/stuck. [jsonName] is the frozen wire string emitted at
/// the server API/SSE boundary.
enum TurnWaitReason {
  sessionLock('session_lock'),
  providerTurn('provider_turn'),
  toolApproval('tool_approval'),
  unknown('unknown');

  final String jsonName;

  const TurnWaitReason(this.jsonName);
}

/// Operator-visible wait/stuck state for an active session turn.
final class TurnWaitStateChangedEvent extends DartclawEvent {
  final String sessionId;
  final String turnId;
  final String? taskId;
  final TurnWaitState state;
  final TurnWaitReason waitReason;
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
