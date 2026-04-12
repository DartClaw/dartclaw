import 'package:dartclaw_models/dartclaw_models.dart' show TaskType;
import 'task_trigger_config.dart';

/// Result of a successful task trigger match.
class TaskTriggerResult {
  /// Parsed task description with trigger prefix and type removed.
  final String description;

  /// Resolved task type for the new task.
  final TaskType type;

  /// Whether the created task should be auto-started.
  final bool autoStart;

  /// Creates a parsed task trigger result.
  const TaskTriggerResult({required this.description, required this.type, required this.autoStart});
}

/// Stateless parser that detects task-creation intent from message text.
class TaskTriggerParser {
  /// Creates a stateless task trigger parser.
  const TaskTriggerParser();

  /// Parses [message] using [config], or returns `null` when no trigger matches.
  TaskTriggerResult? parse(String message, TaskTriggerConfig config, {bool emptyDescriptionError = false}) {
    if (!config.enabled) {
      return null;
    }

    final trimmed = message.trimLeft();
    final prefixLower = config.prefix.toLowerCase();
    if (!trimmed.toLowerCase().startsWith(prefixLower)) {
      return null;
    }

    final afterPrefix = trimmed.substring(config.prefix.length).trim();
    if (afterPrefix.isEmpty) {
      if (!emptyDescriptionError) {
        return null;
      }
      return TaskTriggerResult(description: '', type: _resolveType(config.defaultType), autoStart: config.autoStart);
    }

    final colonIndex = afterPrefix.indexOf(':');
    if (colonIndex > 0) {
      final candidateType = afterPrefix.substring(0, colonIndex).trim().toLowerCase();
      final afterType = afterPrefix.substring(colonIndex + 1).trim();
      if (!candidateType.contains(' ')) {
        if (afterType.isEmpty) {
          if (!emptyDescriptionError) {
            return null;
          }
          return TaskTriggerResult(description: '', type: _resolveType(candidateType), autoStart: config.autoStart);
        }
        return TaskTriggerResult(
          description: afterType,
          type: _resolveType(candidateType),
          autoStart: config.autoStart,
        );
      }
    }

    return TaskTriggerResult(
      description: afterPrefix,
      type: _resolveType(config.defaultType),
      autoStart: config.autoStart,
    );
  }

  TaskType _resolveType(String typeName) => TaskType.values.asNameMap()[typeName.toLowerCase()] ?? TaskType.custom;
}
