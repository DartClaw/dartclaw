import '../task/task_type.dart';

/// A scheduled task template parsed from YAML config (`automation.scheduled_tasks`).
///
/// When the cron fires, a [Task] is created from these template fields and
/// submitted to [TaskService.create] with `autoStart: true`.
class ScheduledTaskDefinition {
  /// Unique schedule ID (user-defined).
  final String id;

  /// 5-field cron expression.
  final String cronExpression;

  /// Whether this schedule is active.
  final bool enabled;

  /// Task title template.
  final String title;

  /// Task description template.
  final String description;

  /// Task type.
  final TaskType type;

  /// Optional acceptance criteria.
  final String? acceptanceCriteria;

  /// Whether created tasks auto-start (queue immediately). Default: true.
  final bool autoStart;

  const ScheduledTaskDefinition({
    required this.id,
    required this.cronExpression,
    this.enabled = true,
    required this.title,
    required this.description,
    required this.type,
    this.acceptanceCriteria,
    this.autoStart = true,
  });

  /// Parses a single entry from the `automation.scheduled_tasks` list.
  ///
  /// Returns `null` and adds a warning if the entry is invalid.
  static ScheduledTaskDefinition? fromYaml(
    Map<dynamic, dynamic> yaml,
    List<String> warnings,
  ) {
    final id = yaml['id'];
    if (id is! String || id.isEmpty) {
      warnings.add('Scheduled task missing or empty "id" — skipping');
      return null;
    }

    final schedule = yaml['schedule'];
    if (schedule is! String || schedule.trim().isEmpty) {
      warnings.add('Scheduled task "$id" missing "schedule" — skipping');
      return null;
    }

    final enabled = yaml['enabled'];
    final isEnabled = enabled is bool ? enabled : true;

    final taskMap = yaml['task'];
    if (taskMap is! Map) {
      warnings.add('Scheduled task "$id" missing "task" section — skipping');
      return null;
    }

    final title = taskMap['title'];
    if (title is! String || title.isEmpty) {
      warnings.add('Scheduled task "$id" missing "task.title" — skipping');
      return null;
    }

    final description = taskMap['description'];
    if (description is! String || description.isEmpty) {
      warnings.add('Scheduled task "$id" missing "task.description" — skipping');
      return null;
    }

    final typeStr = taskMap['type'];
    if (typeStr is! String) {
      warnings.add('Scheduled task "$id" missing "task.type" — skipping');
      return null;
    }

    TaskType type;
    try {
      type = TaskType.values.byName(typeStr);
    } on ArgumentError {
      warnings.add(
        'Scheduled task "$id" invalid task type "$typeStr" — '
        'must be one of: ${TaskType.values.map((t) => t.name).join(', ')}',
      );
      return null;
    }

    final acceptanceCriteria = taskMap['acceptance_criteria'] as String?;
    final autoStart = taskMap['auto_start'];
    final isAutoStart = autoStart is bool ? autoStart : true;

    return ScheduledTaskDefinition(
      id: id,
      cronExpression: schedule.trim(),
      enabled: isEnabled,
      title: title,
      description: description,
      type: type,
      acceptanceCriteria: acceptanceCriteria,
      autoStart: isAutoStart,
    );
  }

  /// Serializes to a map for config API responses and YAML persistence.
  Map<String, dynamic> toJson() => {
    'id': id,
    'schedule': cronExpression,
    'enabled': enabled,
    'task': {
      'title': title,
      'description': description,
      'type': type.name,
      if (acceptanceCriteria != null) 'acceptance_criteria': acceptanceCriteria,
      if (!autoStart) 'auto_start': autoStart,
    },
  };
}
