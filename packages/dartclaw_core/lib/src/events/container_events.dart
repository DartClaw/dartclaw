part of 'dartclaw_event.dart';

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
