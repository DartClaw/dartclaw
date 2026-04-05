part of 'dartclaw_event.dart';

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

/// Fired when a task's cumulative token consumption reaches the warning threshold.
///
/// Downstream consumers (SSE, UI) can use this to display budget warnings.
final class BudgetWarningEvent extends TaskLifecycleEvent {
  @override
  final String taskId;

  /// Fraction of token budget consumed (0.0–1.0+).
  final double consumedPercent;

  /// Actual tokens consumed at time of warning.
  final int consumed;

  /// Token budget limit that is being approached.
  final int limit;

  @override
  final DateTime timestamp;

  BudgetWarningEvent({
    required this.taskId,
    required this.consumedPercent,
    required this.consumed,
    required this.limit,
    required this.timestamp,
  });

  @override
  String toString() =>
      'BudgetWarningEvent(task: $taskId, '
      '${(consumedPercent * 100).toStringAsFixed(0)}% consumed: $consumed/$limit tokens)';
}
