/// Immutable goal value object for persistent task context.
class Goal {
  final String id;
  final String title;
  final String? parentGoalId;
  final String mission;
  final DateTime createdAt;

  const Goal({
    required this.id,
    required this.title,
    this.parentGoalId,
    required this.mission,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (parentGoalId != null) 'parentGoalId': parentGoalId,
    'mission': mission,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Goal.fromJson(Map<String, dynamic> json) => Goal(
    id: json['id'] as String,
    title: json['title'] as String,
    parentGoalId: json['parentGoalId'] as String?,
    mission: json['mission'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  @override
  String toString() => 'Goal($id, "$title")';
}
