part of 'dartclaw_event.dart';

/// Intermediate sealed type for project lifecycle events.
sealed class ProjectLifecycleEvent extends DartclawEvent {
  /// Identifier of the affected project.
  String get projectId;

  @override
  DateTime get timestamp;
}

/// Fired when a project's status changes.
// NOT_ALERTABLE: project lifecycle telemetry — surfaced via SSE only
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
