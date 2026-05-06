part of 'dartclaw_event.dart';

/// Intermediate sealed type for session lifecycle events.
sealed class SessionLifecycleEvent extends DartclawEvent {
  /// Concrete session identifier.
  String get sessionId;

  /// Deterministic session key, if one exists for the session.
  String? get sessionKey;

  /// Session classification such as `web`, `channel`, or `task`.
  String get sessionType;

  @override
  /// Timestamp when the lifecycle event occurred.
  DateTime get timestamp;
}

/// Fired when a new session is created.
// NOT_ALERTABLE: session lifecycle telemetry — surfaced via SSE only
final class SessionCreatedEvent extends SessionLifecycleEvent {
  @override
  /// Identifier of the created session.
  final String sessionId;

  @override
  /// Deterministic session key, if available.
  final String? sessionKey;

  @override
  /// Session classification recorded at creation time.
  final String sessionType;

  @override
  /// Timestamp when the session was created.
  final DateTime timestamp;

  /// Creates a session-created event.
  SessionCreatedEvent({required this.sessionId, this.sessionKey, required this.sessionType, required this.timestamp});

  @override
  String toString() => 'SessionCreatedEvent(id: $sessionId, type: $sessionType)';
}

/// Fired when a session ends normally.
// NOT_ALERTABLE: session lifecycle telemetry — surfaced via SSE only
final class SessionEndedEvent extends SessionLifecycleEvent {
  @override
  /// Identifier of the ended session.
  final String sessionId;

  @override
  /// Deterministic session key, if available.
  final String? sessionKey;

  @override
  /// Session classification recorded at shutdown.
  final String sessionType;

  @override
  /// Timestamp when the session ended.
  final DateTime timestamp;

  /// Creates a session-ended event.
  SessionEndedEvent({required this.sessionId, this.sessionKey, required this.sessionType, required this.timestamp});

  @override
  String toString() => 'SessionEndedEvent(id: $sessionId, type: $sessionType)';
}

/// Fired when a session encounters an error.
// NOT_ALERTABLE: session lifecycle telemetry — surfaced via SSE only
final class SessionErrorEvent extends SessionLifecycleEvent {
  @override
  /// Identifier of the affected session.
  final String sessionId;

  @override
  /// Deterministic session key, if available.
  final String? sessionKey;

  @override
  /// Session classification recorded for the failing session.
  final String sessionType;

  @override
  /// Timestamp when the error was observed.
  final DateTime timestamp;

  /// Error string associated with the session failure.
  final String error;

  /// Creates a session-error event.
  SessionErrorEvent({
    required this.sessionId,
    this.sessionKey,
    required this.sessionType,
    required this.timestamp,
    required this.error,
  });

  @override
  String toString() => 'SessionErrorEvent(id: $sessionId, type: $sessionType, error: $error)';
}
