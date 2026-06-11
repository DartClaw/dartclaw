import 'package:dartclaw_core/dartclaw_core.dart' show TurnOutcome, TurnStatus;

enum TurnWaitState { idle, running, waiting, stuck, cancelling, cancelled, completed, failed }

enum TurnWaitReason {
  sessionLock('session_lock'),
  providerTurn('provider_turn'),
  toolApproval('tool_approval'),
  unknown('unknown');

  final String jsonName;

  const TurnWaitReason(this.jsonName);
}

enum TurnCancelReason {
  operatorCancel('operator_cancel'),
  adminCancel('admin_cancel'),
  automationCancel('automation_cancel');

  final String jsonName;

  const TurnCancelReason(this.jsonName);

  static TurnCancelReason? parse(String value) {
    for (final reason in values) {
      if (reason.jsonName == value) return reason;
    }
    return null;
  }
}

class TurnStatusSnapshot {
  final String sessionId;
  final String? turnId;
  final String? provider;
  final String? taskId;
  final TurnWaitState state;
  final TurnWaitReason? waitReason;
  final DateTime? waitingSince;
  final DateTime? stuckSince;
  final DateTime? globalTimeoutAt;
  final bool canCancel;

  /// Terminal completion timestamp. Internal-only: used to order recent
  /// terminal snapshots across the pool. It is deliberately NOT serialized —
  /// the API's `global_timeout_at` is a *future* deadline and is null for
  /// terminal turns, so completion time must not leak into that field.
  final DateTime? completedAt;

  const TurnStatusSnapshot({
    required this.sessionId,
    required this.state,
    required this.canCancel,
    this.turnId,
    this.provider,
    this.taskId,
    this.waitReason,
    this.waitingSince,
    this.stuckSince,
    this.globalTimeoutAt,
    this.completedAt,
  });

  factory TurnStatusSnapshot.idle(String sessionId) =>
      TurnStatusSnapshot(sessionId: sessionId, state: TurnWaitState.idle, canCancel: false);

  factory TurnStatusSnapshot.fromOutcome({
    required String sessionId,
    required TurnOutcome outcome,
    required String provider,
    String? taskId,
  }) {
    return TurnStatusSnapshot(
      sessionId: sessionId,
      turnId: outcome.turnId,
      provider: provider,
      taskId: taskId,
      state: switch (outcome.status) {
        TurnStatus.completed => TurnWaitState.completed,
        TurnStatus.cancelled => TurnWaitState.cancelled,
        TurnStatus.failed => TurnWaitState.failed,
      },
      canCancel: false,
      // Terminal turns have no future timeout deadline; `global_timeout_at`
      // stays null. Completion time is retained internally for ordering only.
      completedAt: outcome.completedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'turn_id': turnId,
    'provider': provider,
    'task_id': taskId,
    'state': state.name,
    'wait_reason': waitReason?.jsonName,
    'waiting_since': waitingSince?.toIso8601String(),
    'stuck_since': stuckSince?.toIso8601String(),
    'global_timeout_at': globalTimeoutAt?.toIso8601String(),
    'can_cancel': canCancel,
  };
}

class TurnCancelResult {
  final TurnWaitState status;
  final bool releasedSessionLock;

  const TurnCancelResult({required this.status, required this.releasedSessionLock});

  Map<String, dynamic> toJson() => {'status': status.name, 'released_session_lock': releasedSessionLock};
}

class TurnCancelException implements Exception {
  final String code;
  final String message;
  final int statusCode;

  const TurnCancelException(this.code, this.message, {required this.statusCode});
}
