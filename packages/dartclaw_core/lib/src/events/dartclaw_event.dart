import '../task/task_status.dart';

/// Sealed event hierarchy for the DartClaw internal event bus.
///
/// Events are ephemeral fire-and-forget notifications — identity-compared,
/// no `==`/`hashCode` overrides. Sealed classes enable exhaustive pattern
/// matching when new event types are added.
sealed class DartclawEvent {
  DateTime get timestamp;
}

/// Fired when authentication fails on a gateway, login, or webhook surface.
final class FailedAuthEvent extends DartclawEvent {
  final String source;
  final String path;
  final String reason;
  final String? remoteKey;
  final bool limited;
  @override
  final DateTime timestamp;

  FailedAuthEvent({
    required this.source,
    required this.path,
    required this.reason,
    this.remoteKey,
    required this.limited,
    required this.timestamp,
  });

  @override
  String toString() => 'FailedAuthEvent(source: $source, path: $path, reason: $reason, limited: $limited)';
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
  String toString() => 'ConfigChangedEvent(keys: $changedKeys, requiresRestart: $requiresRestart)';
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

  SessionCreatedEvent({required this.sessionId, this.sessionKey, required this.sessionType, required this.timestamp});

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

  SessionEndedEvent({required this.sessionId, this.sessionKey, required this.sessionType, required this.timestamp});

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

/// Intermediate sealed type for task lifecycle events.
sealed class TaskLifecycleEvent extends DartclawEvent {
  String get taskId;
  @override
  DateTime get timestamp;
}

/// Fired on task lifecycle changes.
final class TaskStatusChangedEvent extends TaskLifecycleEvent {
  @override
  final String taskId;
  final TaskStatus oldStatus;
  final TaskStatus newStatus;
  final String trigger;
  @override
  final DateTime timestamp;

  TaskStatusChangedEvent({
    required this.taskId,
    required this.oldStatus,
    required this.newStatus,
    required this.trigger,
    required this.timestamp,
  });

  @override
  String toString() =>
      'TaskStatusChangedEvent(task: $taskId, ${oldStatus.name} -> ${newStatus.name}, trigger: $trigger)';
}

/// Fired when a task enters review and artifacts are ready.
final class TaskReviewReadyEvent extends TaskLifecycleEvent {
  @override
  final String taskId;
  final int artifactCount;
  final List<String> artifactKinds;
  @override
  final DateTime timestamp;

  TaskReviewReadyEvent({
    required this.taskId,
    required this.artifactCount,
    required this.artifactKinds,
    required this.timestamp,
  });

  @override
  String toString() => 'TaskReviewReadyEvent(task: $taskId, artifacts: $artifactCount, kinds: $artifactKinds)';
}

/// Intermediate sealed type for container lifecycle events.
sealed class ContainerLifecycleEvent extends DartclawEvent {
  String get profileId;
  String get containerName;
  @override
  DateTime get timestamp;
}

/// Fired when a container starts successfully.
final class ContainerStartedEvent extends ContainerLifecycleEvent {
  @override
  final String profileId;
  @override
  final String containerName;
  @override
  final DateTime timestamp;

  ContainerStartedEvent({required this.profileId, required this.containerName, required this.timestamp});

  @override
  String toString() => 'ContainerStartedEvent(profile: $profileId, container: $containerName)';
}

/// Fired when a container is gracefully stopped.
final class ContainerStoppedEvent extends ContainerLifecycleEvent {
  @override
  final String profileId;
  @override
  final String containerName;
  @override
  final DateTime timestamp;

  ContainerStoppedEvent({required this.profileId, required this.containerName, required this.timestamp});

  @override
  String toString() => 'ContainerStoppedEvent(profile: $profileId, container: $containerName)';
}

/// Fired when a container crash is detected.
final class ContainerCrashedEvent extends ContainerLifecycleEvent {
  @override
  final String profileId;
  @override
  final String containerName;
  final String error;
  @override
  final DateTime timestamp;

  ContainerCrashedEvent({
    required this.profileId,
    required this.containerName,
    required this.error,
    required this.timestamp,
  });

  @override
  String toString() => 'ContainerCrashedEvent(profile: $profileId, container: $containerName, error: $error)';
}

/// Intermediate sealed type for agent observer events.
sealed class AgentLifecycleEvent extends DartclawEvent {
  int get runnerId;
  @override
  DateTime get timestamp;
}

/// Fired when a runner transitions between states (idle/busy/stopped/crashed).
final class AgentStateChangedEvent extends AgentLifecycleEvent {
  @override
  final int runnerId;
  final String state;
  final String? currentTaskId;
  @override
  final DateTime timestamp;

  AgentStateChangedEvent({required this.runnerId, required this.state, this.currentTaskId, required this.timestamp});

  @override
  String toString() => 'AgentStateChangedEvent(runner: $runnerId, state: $state, task: $currentTaskId)';
}
