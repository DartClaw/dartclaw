/// Sealed event hierarchy for the DartClaw internal event bus.
///
/// Events are ephemeral fire-and-forget notifications — identity-compared,
/// no `==`/`hashCode` overrides. Sealed classes enable exhaustive pattern
/// matching when new event types are added.
sealed class DartclawEvent {
  DateTime get timestamp;
}

/// Fired when a guard blocks or warns on input.
final class GuardBlockEvent extends DartclawEvent {
  final String guardName;
  final String guardCategory;
  final String verdict;
  final String? verdictMessage;
  final String hookPoint;
  final String? sessionKey;
  final String? sessionId;
  final String? channel;
  final String? peerId;
  @override
  final DateTime timestamp;

  GuardBlockEvent({
    required this.guardName,
    required this.guardCategory,
    required this.verdict,
    this.verdictMessage,
    required this.hookPoint,
    this.sessionKey,
    this.sessionId,
    this.channel,
    this.peerId,
    required this.timestamp,
  });

  @override
  String toString() =>
      'GuardBlockEvent(guard: $guardName, category: $guardCategory, verdict: $verdict, hook: $hookPoint)';
}

/// Fired when configuration values change via the config API.
final class ConfigChangedEvent extends DartclawEvent {
  final List<String> changedKeys;
  final Map<String, dynamic> oldValues;
  final Map<String, dynamic> newValues;
  final bool requiresRestart;
  @override
  final DateTime timestamp;

  ConfigChangedEvent({
    required this.changedKeys,
    required this.oldValues,
    required this.newValues,
    required this.requiresRestart,
    required this.timestamp,
  });

  @override
  String toString() =>
      'ConfigChangedEvent(keys: $changedKeys, requiresRestart: $requiresRestart)';
}

/// Intermediate sealed type for session lifecycle events.
sealed class SessionLifecycleEvent extends DartclawEvent {
  String get sessionId;
  String? get sessionKey;
  String get sessionType;
  @override
  DateTime get timestamp;
}

/// Fired when a new session is created.
final class SessionCreatedEvent extends SessionLifecycleEvent {
  @override
  final String sessionId;
  @override
  final String? sessionKey;
  @override
  final String sessionType;
  @override
  final DateTime timestamp;

  SessionCreatedEvent({
    required this.sessionId,
    this.sessionKey,
    required this.sessionType,
    required this.timestamp,
  });

  @override
  String toString() => 'SessionCreatedEvent(id: $sessionId, type: $sessionType)';
}

/// Fired when a session ends normally.
final class SessionEndedEvent extends SessionLifecycleEvent {
  @override
  final String sessionId;
  @override
  final String? sessionKey;
  @override
  final String sessionType;
  @override
  final DateTime timestamp;

  SessionEndedEvent({
    required this.sessionId,
    this.sessionKey,
    required this.sessionType,
    required this.timestamp,
  });

  @override
  String toString() => 'SessionEndedEvent(id: $sessionId, type: $sessionType)';
}

/// Fired when a session encounters an error.
final class SessionErrorEvent extends SessionLifecycleEvent {
  @override
  final String sessionId;
  @override
  final String? sessionKey;
  @override
  final String sessionType;
  @override
  final DateTime timestamp;
  final String error;

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
