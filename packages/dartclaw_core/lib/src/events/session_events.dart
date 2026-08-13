part of 'dartclaw_event.dart';

/// Intermediate sealed type for session lifecycle events.
sealed class SessionLifecycleEvent extends DartclawEvent {
  /// Concrete session identifier.
  final String sessionId;

  /// Deterministic session key, if one exists for the session.
  final String? sessionKey;

  /// Session classification such as `web`, `channel`, or `task`.
  final String sessionType;

  @override
  /// Timestamp when the lifecycle event occurred.
  final DateTime timestamp;

  /// Creates a session lifecycle event.
  new({required this.sessionId, this.sessionKey, required this.sessionType, required this.timestamp});
}

/// Fired when a new session is created.
// NOT_ALERTABLE: session lifecycle telemetry — surfaced via SSE only
final class SessionCreatedEvent extends SessionLifecycleEvent {
  /// Creates a session-created event.
  new({required super.sessionId, super.sessionKey, required super.sessionType, required super.timestamp});

  @override
  String toString() => 'SessionCreatedEvent(id: $sessionId, type: $sessionType)';
}

/// Fired when a session ends normally.
// NOT_ALERTABLE: session lifecycle telemetry — surfaced via SSE only
final class SessionEndedEvent extends SessionLifecycleEvent {
  /// Creates a session-ended event.
  new({required super.sessionId, super.sessionKey, required super.sessionType, required super.timestamp});

  @override
  String toString() => 'SessionEndedEvent(id: $sessionId, type: $sessionType)';
}

/// Fired when a session encounters an error.
// NOT_ALERTABLE: session lifecycle telemetry — surfaced via SSE only
final class SessionErrorEvent extends SessionLifecycleEvent {
  /// Error string associated with the session failure.
  final String error;

  /// Creates a session-error event.
  new({
    required super.sessionId,
    super.sessionKey,
    required super.sessionType,
    required super.timestamp,
    required this.error,
  });

  @override
  String toString() => 'SessionErrorEvent(id: $sessionId, type: $sessionType, error: $error)';
}
