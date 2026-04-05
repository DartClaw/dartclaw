/// Immutable goal value object for persistent task context.
///
/// Goals let higher-level missions group one or more [Task] records while
/// keeping the mission statement separate from individual execution details.
class Goal {
  /// Unique identifier for this goal.
  final String id;

  /// Short human-readable name shown in task and planning UIs.
  final String title;

  /// Optional parent goal identifier for hierarchical planning.
  final String? parentGoalId;

  /// Mission statement or desired outcome for this goal.
  final String mission;

  /// Timestamp when this goal was created.
  final DateTime createdAt;

  /// Optional maximum token budget for tasks created under this goal.
  ///
  /// When a task has no per-task budget and has this goal as its parent,
  /// this value is used as the budget (before global config defaults).
  final int? maxTokens;

  /// Creates an immutable goal record.
  const Goal({
    required this.id,
    required this.title,
    this.parentGoalId,
    required this.mission,
    required this.createdAt,
    this.maxTokens,
  });

  /// Serializes this goal to the JSON shape used by persistence layers.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (parentGoalId != null) 'parentGoalId': parentGoalId,
    'mission': mission,
    'createdAt': createdAt.toIso8601String(),
    if (maxTokens != null) 'maxTokens': maxTokens,
  };

  /// Deserializes a goal from persisted JSON.
  factory Goal.fromJson(Map<String, dynamic> json) => Goal(
    id: json['id'] as String,
    title: json['title'] as String,
    parentGoalId: json['parentGoalId'] as String?,
    mission: json['mission'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    maxTokens: (json['maxTokens'] as num?)?.toInt(),
  );

  @override
  String toString() => 'Goal($id, "$title")';
}
