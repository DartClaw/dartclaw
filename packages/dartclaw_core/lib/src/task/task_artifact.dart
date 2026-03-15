/// Artifact classification produced by task execution.
enum ArtifactKind {
  /// Code diff or patch output produced by a task.
  diff,

  /// Human-readable document such as notes, plans, or reports.
  document,

  /// Structured machine-readable output such as JSON or CSV.
  data,
}

/// A persisted output produced for a task.
class TaskArtifact {
  /// Unique identifier for this artifact row.
  final String id;

  /// Identifier of the [Task] that produced this artifact.
  final String taskId;

  /// Display name for this artifact.
  final String name;

  /// Classification of the artifact payload.
  final ArtifactKind kind;

  /// Filesystem path or logical location of the artifact contents.
  final String path;

  /// Timestamp when the artifact was recorded.
  final DateTime createdAt;

  /// Creates an immutable task artifact record.
  const TaskArtifact({
    required this.id,
    required this.taskId,
    required this.name,
    required this.kind,
    required this.path,
    required this.createdAt,
  });

  /// Serializes this artifact to the JSON shape used by repositories.
  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'name': name,
    'kind': kind.name,
    'path': path,
    'createdAt': createdAt.toIso8601String(),
  };

  /// Deserializes an artifact from persisted JSON.
  factory TaskArtifact.fromJson(Map<String, dynamic> json) => TaskArtifact(
    id: json['id'] as String,
    taskId: json['taskId'] as String,
    name: json['name'] as String,
    kind: ArtifactKind.values.byName(json['kind'] as String),
    path: json['path'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
