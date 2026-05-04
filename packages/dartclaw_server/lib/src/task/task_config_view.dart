import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskConfig;
import 'package:logging/logging.dart';

/// Typed view over generic task configuration used by task execution.
final class TaskConfigView {
  TaskConfigView(this.task, {Logger? log}) : _log = log ?? Logger('TaskConfigView');

  final Task task;
  final Logger _log;

  List<String>? get allowedTools {
    final raw = task.configJson['allowedTools'];
    if (raw is! List) return null;
    try {
      return raw.cast<String>().toList(growable: false);
    } catch (error) {
      _log.warning('Task ${task.id}: malformed allowedTools in configJson, ignoring: $error');
      return null;
    }
  }

  bool get isReadOnly => task.configJson['readOnly'] == true;

  bool get isWorkflowOrchestrated => task.workflowStepExecution != null;

  String? get reviewMode {
    final raw = task.configJson['reviewMode'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (!const {'auto-accept', 'mandatory', 'coding-only'}.contains(trimmed)) {
      _log.warning('Task ${task.id}: unknown reviewMode "$trimmed", using default');
      return null;
    }
    return trimmed;
  }

  TaskStatus get postCompletionStatus {
    return switch (reviewMode) {
      'auto-accept' => TaskStatus.accepted,
      'mandatory' => TaskStatus.review,
      'coding-only' => isCodingTask ? TaskStatus.review : TaskStatus.accepted,
      _ => TaskStatus.review,
    };
  }

  bool get isCodingTask => task.type == TaskType.coding;

  bool get needsWorktree {
    if (isWorkflowOrchestrated) {
      return isCodingTask || task.configJson['_workflowNeedsWorktree'] == true;
    }
    return task.type == TaskType.coding || task.configJson['_workflowNeedsWorktree'] == true;
  }

  String? get model => task.model;

  String? get effort {
    final raw = task.configJson['effort'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? get pushBackComment {
    final raw = task.configJson['pushBackComment'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? get lastError {
    final raw = task.configJson['lastError'];
    return raw is String ? raw : null;
  }

  String? get continueSessionId {
    final raw = task.configJson['_continueSessionId'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? get requiredInputPath {
    final raw = task.configJson['requiredInputPath'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? get tokenBudget {
    if (task.maxTokens != null && task.maxTokens! > 0) return task.maxTokens;
    final primary = task.configJson['tokenBudget'];
    if (primary != null) {
      return _positiveInt(primary);
    }
    final legacy = task.configJson['budget'];
    if (legacy != null) {
      _log.warning('Task ${task.id}: "budget" config key is deprecated - use "tokenBudget"');
      return _positiveInt(legacy);
    }
    return null;
  }

  String? get baseRef {
    final raw = task.configJson['_baseRef'] ?? task.configJson['baseRef'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<List<String>> readWorkflowFollowUpPrompts(Task task, WorkflowStepExecutionRepository repo) {
    return WorkflowTaskConfig.readFollowUpPrompts(task, repo);
  }

  static Future<Map<String, dynamic>?> readWorkflowStructuredSchema(Task task, WorkflowStepExecutionRepository repo) {
    return WorkflowTaskConfig.readStructuredSchema(task, repo);
  }

  static Future<Map<String, dynamic>?> readWorkflowStructuredOutputPayload(
    Task task,
    WorkflowStepExecutionRepository repo,
  ) {
    return WorkflowTaskConfig.readStructuredOutputPayload(task, repo);
  }

  static Future<String?> readWorkflowProviderSessionId(Task task, WorkflowStepExecutionRepository repo) {
    return WorkflowTaskConfig.readProviderSessionId(task, repo);
  }

  static int? _positiveInt(Object? value) {
    if (value is int && value > 0) return value;
    if (value is num) {
      final intValue = value.toInt();
      return intValue > 0 ? intValue : null;
    }
    return null;
  }
}
