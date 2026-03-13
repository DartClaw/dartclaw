/// Artifact classification produced by task execution.
enum ArtifactKind { diff, document, data }

/// A persisted output produced for a task.
class TaskArtifact {
  final String id;
  final String taskId;
  final String name;
  final ArtifactKind kind;
  final String path;
  final DateTime createdAt;

  const TaskArtifact({
    required this.id,
    required this.taskId,
    required this.name,
    required this.kind,
    required this.path,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'name': name,
    'kind': kind.name,
    'path': path,
    'createdAt': createdAt.toIso8601String(),
  };

  factory TaskArtifact.fromJson(Map<String, dynamic> json) => TaskArtifact(
    id: json['id'] as String,
    taskId: json['taskId'] as String,
    name: json['name'] as String,
    kind: ArtifactKind.values.byName(json['kind'] as String),
    path: json['path'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
