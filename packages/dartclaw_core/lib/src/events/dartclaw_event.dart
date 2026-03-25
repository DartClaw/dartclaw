import 'package:dartclaw_models/dartclaw_models.dart' show ProjectStatus;

import '../task/task_status.dart';

/// Sealed event hierarchy for the DartClaw internal event bus.
///
/// Events are ephemeral fire-and-forget notifications — identity-compared,
/// no `==`/`hashCode` overrides. Sealed classes enable exhaustive pattern
/// matching when new event types are added.
sealed class DartclawEvent {
  /// Timestamp when the event occurred.
  DateTime get timestamp;
}

/// Fired when authentication fails on a gateway, login, or webhook surface.
final class FailedAuthEvent extends DartclawEvent {
  /// Surface that emitted the authentication failure.
  final String source;

  /// Request path or endpoint associated with the failure.
  final String path;

  /// Human-readable explanation of the failure.
  final String reason;

  /// Optional remote key such as IP address or token fingerprint.
  final String? remoteKey;

  /// Whether rate limiting or a hard limit was applied.
  final bool limited;
  @override
  /// Timestamp when the authentication failure occurred.
  final DateTime timestamp;

  /// Creates an authentication failure event.
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
  /// Stable name of the guard that emitted the verdict.
  final String guardName;

  /// High-level guard category such as `file` or `network`.
  final String guardCategory;

  /// Verdict label such as `warn` or `block`.
  final String verdict;

  /// Optional explanatory message returned by the guard.
  final String? verdictMessage;

  /// Hook point where the guard evaluated the input.
  final String hookPoint;

  /// Raw provider-native tool name associated with the verdict, if any.
  final String? rawProviderToolName;

  /// Deterministic session key associated with the event, if known.
  final String? sessionKey;

  /// Concrete session id associated with the event, if known.
  final String? sessionId;

  /// Channel associated with the event, if any.
  final String? channel;

  /// Peer identifier associated with the event, if any.
  final String? peerId;
  @override
  /// Timestamp when the guard verdict was produced.
  final DateTime timestamp;

  /// Creates a guard block-or-warn event.
  GuardBlockEvent({
    required this.guardName,
    required this.guardCategory,
    required this.verdict,
    this.verdictMessage,
    required this.hookPoint,
    this.rawProviderToolName,
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
  /// Fully-qualified config keys that changed.
  final List<String> changedKeys;

  /// Previous values for changed keys.
  final Map<String, dynamic> oldValues;

  /// New values for changed keys.
  final Map<String, dynamic> newValues;

  /// Whether the change requires a runtime restart to fully apply.
  final bool requiresRestart;
  @override
  /// Timestamp when the config change was recorded.
  final DateTime timestamp;

  /// Creates a configuration change event.
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

/// Intermediate sealed type for task lifecycle events.
sealed class TaskLifecycleEvent extends DartclawEvent {
  /// Identifier of the task associated with the event.
  String get taskId;
  @override
  /// Timestamp when the lifecycle event occurred.
  DateTime get timestamp;
}

/// Fired on task lifecycle changes.
final class TaskStatusChangedEvent extends TaskLifecycleEvent {
  @override
  /// Identifier of the affected task.
  final String taskId;

  /// Previous lifecycle status before the transition.
  final TaskStatus oldStatus;

  /// New lifecycle status after the transition.
  final TaskStatus newStatus;

  /// Trigger or subsystem that initiated the transition.
  final String trigger;
  @override
  /// Timestamp when the transition was recorded.
  final DateTime timestamp;

  /// Creates a task-status-changed event.
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
  /// Identifier of the task ready for review.
  final String taskId;

  /// Number of artifacts currently attached to the task.
  final int artifactCount;

  /// Artifact kind names attached to the task.
  final List<String> artifactKinds;
  @override
  /// Timestamp when the task entered review.
  final DateTime timestamp;

  /// Creates a task-review-ready event.
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
  /// Security profile identifier used for the container.
  String get profileId;

  /// Runtime container name.
  String get containerName;
  @override
  /// Timestamp when the container event occurred.
  DateTime get timestamp;
}

/// Fired when a container starts successfully.
final class ContainerStartedEvent extends ContainerLifecycleEvent {
  @override
  /// Security profile identifier used for the container.
  final String profileId;
  @override
  /// Name of the started container.
  final String containerName;
  @override
  /// Timestamp when the container started.
  final DateTime timestamp;

  /// Creates a container-started event.
  ContainerStartedEvent({required this.profileId, required this.containerName, required this.timestamp});

  @override
  String toString() => 'ContainerStartedEvent(profile: $profileId, container: $containerName)';
}

/// Fired when a container is gracefully stopped.
final class ContainerStoppedEvent extends ContainerLifecycleEvent {
  @override
  /// Security profile identifier used for the container.
  final String profileId;
  @override
  /// Name of the stopped container.
  final String containerName;
  @override
  /// Timestamp when the container stopped.
  final DateTime timestamp;

  /// Creates a container-stopped event.
  ContainerStoppedEvent({required this.profileId, required this.containerName, required this.timestamp});

  @override
  String toString() => 'ContainerStoppedEvent(profile: $profileId, container: $containerName)';
}

/// Fired when a container crash is detected.
final class ContainerCrashedEvent extends ContainerLifecycleEvent {
  @override
  /// Security profile identifier used for the container.
  final String profileId;
  @override
  /// Name of the crashed container.
  final String containerName;

  /// Error string or crash reason.
  final String error;
  @override
  /// Timestamp when the crash was detected.
  final DateTime timestamp;

  /// Creates a container-crashed event.
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
  /// Runner identifier associated with the event.
  int get runnerId;
  @override
  /// Timestamp when the agent event occurred.
  DateTime get timestamp;
}

/// Fired when a runner transitions between states (idle/busy/stopped/crashed).
final class AgentStateChangedEvent extends AgentLifecycleEvent {
  @override
  /// Runner identifier whose state changed.
  final int runnerId;

  /// New runner state label such as `idle`, `busy`, or `stopped`.
  final String state;

  /// Current task id assigned to the runner, if any.
  final String? currentTaskId;
  @override
  /// Timestamp when the state change occurred.
  final DateTime timestamp;

  /// Creates an agent-state-changed event.
  AgentStateChangedEvent({required this.runnerId, required this.state, this.currentTaskId, required this.timestamp});

  @override
  String toString() => 'AgentStateChangedEvent(runner: $runnerId, state: $state, task: $currentTaskId)';
}

/// Fired when a channel user explicitly invokes `@advisor`.
final class AdvisorMentionEvent extends DartclawEvent {
  /// Sender identifier from the originating channel.
  final String senderJid;

  /// Originating channel type.
  final String channelType;

  /// Channel recipient used to route advisor responses.
  final String recipientId;

  /// Thread or group identifier for the originating conversation.
  final String? threadId;

  /// Full user message that invoked the advisor.
  final String messageText;

  /// Session key associated with the originating conversation.
  final String sessionKey;

  /// Bound task id when the mention occurred inside a routed task context.
  final String? taskId;

  @override
  final DateTime timestamp;

  AdvisorMentionEvent({
    required this.senderJid,
    required this.channelType,
    required this.recipientId,
    this.threadId,
    required this.messageText,
    required this.sessionKey,
    this.taskId,
    required this.timestamp,
  });

  @override
  String toString() =>
      'AdvisorMentionEvent(sender: $senderJid, channel: $channelType, recipient: $recipientId, session: $sessionKey)';
}

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

/// Intermediate sealed type for project lifecycle events.
sealed class ProjectLifecycleEvent extends DartclawEvent {
  /// Identifier of the affected project.
  String get projectId;
  @override
  DateTime get timestamp;
}

/// Fired when a project's status changes.
final class ProjectStatusChangedEvent extends ProjectLifecycleEvent {
  @override
  /// Identifier of the affected project.
  final String projectId;

  /// Previous status, or null if this is the initial creation event.
  final ProjectStatus? oldStatus;

  /// New status after the transition.
  final ProjectStatus newStatus;
  @override
  /// Timestamp when the status change occurred.
  final DateTime timestamp;

  /// Creates a project-status-changed event.
  ProjectStatusChangedEvent({
    required this.projectId,
    required this.oldStatus,
    required this.newStatus,
    required this.timestamp,
  });

  @override
  String toString() =>
      'ProjectStatusChangedEvent(project: $projectId, '
      '${oldStatus?.name ?? "null"} -> ${newStatus.name})';
}

/// Fired when a new task timeline event is persisted.
///
/// Carries primitive fields only — no dependency on [TaskEvent] model.
/// Downstream consumers (SSE, dashboard) subscribe to push real-time updates.
final class TaskEventCreatedEvent extends TaskLifecycleEvent {
  @override
  final String taskId;

  /// Unique identifier of the persisted event.
  final String eventId;

  /// Event kind name (e.g., 'statusChanged', 'toolCalled').
  final String kind;

  /// Event-specific metadata.
  final Map<String, dynamic> details;

  @override
  final DateTime timestamp;

  TaskEventCreatedEvent({
    required this.taskId,
    required this.eventId,
    required this.kind,
    required this.details,
    required this.timestamp,
  });

  @override
  String toString() => 'TaskEventCreatedEvent(task: $taskId, kind: $kind)';
}

/// Fired when the advisor agent produces a structured insight.
final class AdvisorInsightEvent extends DartclawEvent {
  /// Advisor assessment (for example `on_track` or `stuck`).
  final String status;

  /// Primary observation produced by the advisor.
  final String observation;

  /// Optional suggestion produced by the advisor.
  final String? suggestion;

  /// Trigger type that caused the advisor to fire.
  final String triggerType;

  /// Task ids referenced by the advisor.
  final List<String> taskIds;

  /// Session key observed by the advisor.
  final String sessionKey;

  @override
  final DateTime timestamp;

  AdvisorInsightEvent({
    required this.status,
    required this.observation,
    this.suggestion,
    required this.triggerType,
    required this.taskIds,
    required this.sessionKey,
    required this.timestamp,
  });

  @override
  String toString() =>
      'AdvisorInsightEvent(status: $status, trigger: $triggerType, session: $sessionKey, tasks: $taskIds)';
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
