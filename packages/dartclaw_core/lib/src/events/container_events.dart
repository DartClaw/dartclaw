part of 'dartclaw_event.dart';

/// Intermediate sealed type for container lifecycle events.
sealed class ContainerLifecycleEvent extends DartclawEvent {
  /// Security profile identifier used for the container.
  final String profileId;

  /// Runtime container name.
  final String containerName;

  @override
  /// Timestamp when the container event occurred.
  final DateTime timestamp;

  /// Creates a container lifecycle event.
  ContainerLifecycleEvent({required this.profileId, required this.containerName, required this.timestamp});
}

/// Fired when a container starts successfully.
// NOT_ALERTABLE: normal lifecycle telemetry — no operator action required
final class ContainerStartedEvent extends ContainerLifecycleEvent {
  /// Creates a container-started event.
  ContainerStartedEvent({required super.profileId, required super.containerName, required super.timestamp});

  @override
  String toString() => 'ContainerStartedEvent(profile: $profileId, container: $containerName)';
}

/// Fired when a container is gracefully stopped.
// NOT_ALERTABLE: normal lifecycle telemetry — no operator action required
final class ContainerStoppedEvent extends ContainerLifecycleEvent {
  /// Creates a container-stopped event.
  ContainerStoppedEvent({required super.profileId, required super.containerName, required super.timestamp});

  @override
  String toString() => 'ContainerStoppedEvent(profile: $profileId, container: $containerName)';
}

/// Fired when a container crash is detected.
final class ContainerCrashedEvent extends ContainerLifecycleEvent {
  /// Error string or crash reason.
  final String error;

  /// The task whose execution held the crashed container, when it was leased
  /// for one.
  ///
  /// A container belongs to exactly one execution authority, so this is what
  /// crash attribution keys on. `null` means the authority was not a task's —
  /// the primary lane or a logical-agent session — and no task is affected.
  final String? taskId;

  /// Creates a container-crashed event.
  ContainerCrashedEvent({
    required super.profileId,
    required super.containerName,
    required this.error,
    required super.timestamp,
    this.taskId,
  });

  @override
  String toString() =>
      'ContainerCrashedEvent(profile: $profileId, container: $containerName, '
      '${taskId == null ? '' : 'task: $taskId, '}error: $error)';
}
