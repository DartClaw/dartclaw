import 'dart:convert';

/// The kind of event recorded in a task timeline.
sealed class TaskEventKind {
  /// Stable string identifier for persistence and serialization.
  String get name;

  const TaskEventKind();

  factory TaskEventKind.fromName(String name) => switch (name) {
    'statusChanged' => const StatusChanged(),
    'toolCalled' => const ToolCalled(),
    'artifactCreated' => const ArtifactCreated(),
    'pushBack' => const PushBack(),
    'tokenUpdate' => const TokenUpdate(),
    'error' => const TaskErrorEvent(),
    _ => throw ArgumentError('Unknown TaskEventKind: $name'),
  };
}

/// Task lifecycle status transition.
final class StatusChanged extends TaskEventKind {
  @override
  String get name => 'statusChanged';
  const StatusChanged();
}

/// A tool was invoked during agent execution.
final class ToolCalled extends TaskEventKind {
  @override
  String get name => 'toolCalled';
  const ToolCalled();
}

/// An artifact was created and attached to the task.
final class ArtifactCreated extends TaskEventKind {
  @override
  String get name => 'artifactCreated';
  const ArtifactCreated();
}

/// Task was pushed back from review with feedback.
final class PushBack extends TaskEventKind {
  @override
  String get name => 'pushBack';
  const PushBack();
}

/// Token consumption update after a completed turn.
final class TokenUpdate extends TaskEventKind {
  @override
  String get name => 'tokenUpdate';
  const TokenUpdate();
}

/// An error occurred during task execution.
final class TaskErrorEvent extends TaskEventKind {
  @override
  String get name => 'error';
  const TaskErrorEvent();
}

/// An append-only event recording something that happened during a task.
///
/// Events form the user-visible timeline on the task detail page.
/// Each event has a [kind] that determines the structure of [details].
///
/// Details structure per kind:
/// - `statusChanged`: `{oldStatus, newStatus, trigger}`
/// - `toolCalled`: `{name, success, durationMs, ?errorType, ?context}`
/// - `artifactCreated`: `{name, kind}`
/// - `pushBack`: `{comment}`
/// - `tokenUpdate`: `{inputTokens, outputTokens, ?cacheReadTokens, ?cacheWriteTokens}`
/// - `error`: `{message}`
class TaskEvent {
  /// Unique identifier for this event.
  final String id;

  /// Task this event belongs to.
  final String taskId;

  /// When the event occurred.
  final DateTime timestamp;

  /// Classification of the event.
  final TaskEventKind kind;

  /// Event-specific metadata. Structure depends on [kind].
  final Map<String, dynamic> details;

  const TaskEvent({
    required this.id,
    required this.taskId,
    required this.timestamp,
    required this.kind,
    this.details = const {},
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'timestamp': timestamp.toIso8601String(),
    'kind': kind.name,
    'details': details,
  };

  factory TaskEvent.fromJson(Map<String, dynamic> json) => TaskEvent(
    id: json['id'] as String,
    taskId: json['taskId'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
    kind: TaskEventKind.fromName(json['kind'] as String),
    details: (json['details'] as Map<String, dynamic>?) ?? const {},
  );

  /// Encodes this event to a JSON string (for storage).
  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskEvent &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          taskId == other.taskId &&
          timestamp == other.timestamp &&
          kind.name == other.kind.name;

  @override
  int get hashCode => Object.hash(id, taskId, timestamp, kind.name);

  @override
  String toString() => 'TaskEvent(id: $id, taskId: $taskId, kind: ${kind.name}, timestamp: $timestamp)';
}
