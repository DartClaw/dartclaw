import 'dart:async';

/// Zone-based log correlation context.
///
/// Set session/turn IDs once via [runWith]; read anywhere downstream
/// via [sessionId] / [turnId]. Zone values are immutable per zone.
class LogContext {
  static String? get sessionId => Zone.current[#logSessionId] as String?;
  static String? get turnId => Zone.current[#logTurnId] as String?;

  static R runWith<R>(R Function() body, {String? sessionId, String? turnId}) {
    return runZoned(body, zoneValues: {#logSessionId: ?sessionId, #logTurnId: ?turnId});
  }
}
