import 'dart:convert';

/// The kind of event recorded in a task timeline.
enum TaskEventKind {
  statusChanged,
  toolCalled,
  artifactCreated,
  structuredOutputInlineUsed,
  structuredOutputFallbackUsed,
  pushBack,
  tokenUpdate,
  taskError,
  compaction;

  /// Constructs a [TaskEventKind] from its persistence name.
  ///
  /// Handles the legacy wire value `'error'` (was `TaskErrorEvent.name`)
  /// in addition to the current enum value names.
  static TaskEventKind fromName(String name) => switch (name) {
    'error' => taskError,
    _ => values.byName(name),
  };
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
/// - `structuredOutputInlineUsed`: `{stepId, outputKey}`
/// - `structuredOutputFallbackUsed`: `{stepId, outputKey, failureReason, ?providerSubtype}`
/// - `pushBack`: `{comment}`
/// - `tokenUpdate`: `{inputTokens, outputTokens, ?cacheReadTokens, ?cacheWriteTokens}`
/// - `taskError`: `{message}`
/// - `compaction`: `{trigger, sessionId, ?preTokens}`
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

  /// Creates a [TaskEvent] value.
  const TaskEvent({
    required this.id,
    required this.taskId,
    required this.timestamp,
    required this.kind,
    this.details = const {},
  });

  /// Serializes this event to a JSON-ready map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'timestamp': timestamp.toIso8601String(),
    'kind': kind.name,
    'details': details,
  };

  /// Reconstructs a [TaskEvent] from its JSON representation.
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
          kind == other.kind;

  @override
  int get hashCode => Object.hash(id, taskId, timestamp, kind);

  @override
  String toString() => 'TaskEvent(id: $id, taskId: $taskId, kind: ${kind.name}, timestamp: $timestamp)';
}
