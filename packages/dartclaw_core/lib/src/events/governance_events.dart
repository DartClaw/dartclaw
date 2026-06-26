part of 'dartclaw_event.dart';

/// Fired when the loop detector identifies a potential agent loop.
final class LoopDetectedEvent extends DartclawEvent {
  /// Session where the loop was detected.
  final String sessionId;

  /// Detection mechanism that triggered (e.g. `'turnChainDepth'`).
  final String mechanism;

  /// Human-readable detection message.
  final String message;

  /// Action taken (`'abort'` or `'warn'`).
  final String action;

  /// Additional detection details (thresholds, counts).
  final Map<String, dynamic> detail;

  @override
  /// Timestamp when the loop was detected.
  final DateTime timestamp;

  /// Creates a loop-detected event.
  LoopDetectedEvent({
    required this.sessionId,
    required this.mechanism,
    required this.message,
    required this.action,
    this.detail = const {},
    required this.timestamp,
  });

  @override
  String toString() => 'LoopDetectedEvent(session: $sessionId, mechanism: $mechanism, action: $action)';
}

/// Fired when an admin sender triggers an emergency stop via the `/stop` command.
final class EmergencyStopEvent extends DartclawEvent {
  /// Display name or sender ID of who triggered the stop.
  final String stoppedBy;

  /// Number of active turns that were cancelled.
  final int turnsCancelled;

  /// Number of tasks transitioned to cancelled.
  final int tasksCancelled;

  @override
  /// Timestamp when the emergency stop was executed.
  final DateTime timestamp;

  /// Creates an emergency-stop event.
  EmergencyStopEvent({
    required this.stoppedBy,
    required this.turnsCancelled,
    required this.tasksCancelled,
    required this.timestamp,
  });

  @override
  String toString() => 'EmergencyStopEvent(stoppedBy: $stoppedBy, turns: $turnsCancelled, tasks: $tasksCancelled)';
}

/// Fired when per-server outbound MCP governance counters change.
final class OutboundMcpGovernanceEvent extends DartclawEvent {
  /// External MCP server whose counters are reported.
  final String serverName;

  /// Calls allowed in the current window.
  final int callsUsed;

  /// Tokens consumed in the current window.
  final int tokensUsed;

  /// Calls rejected by governance in the current window.
  final int rejections;

  /// Reason for the latest rejection, when this event follows a denial.
  final String? rejectionReason;

  @override
  final DateTime timestamp;

  /// Creates an outbound MCP governance counter event.
  OutboundMcpGovernanceEvent({
    required this.serverName,
    required this.callsUsed,
    required this.tokensUsed,
    required this.rejections,
    this.rejectionReason,
    required this.timestamp,
  });

  @override
  String toString() =>
      'OutboundMcpGovernanceEvent(server: $serverName, calls: $callsUsed, tokens: $tokensUsed, rejections: $rejections)';
}
