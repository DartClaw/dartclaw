import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowStepExecutionRepository, WorkflowTaskConfig;
import 'package:logging/logging.dart';

import '../execution_policy_resolver.dart';

/// Typed view over generic task configuration used by task execution.
final class TaskConfigView {
  static const securityProfileKey = 'securityProfile';
  static const needsWorktreeKey = WorkflowTaskConfig.needsWorktree;

  new(this.task, {Logger? log}) : _log = log ?? Logger('TaskConfigView');

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
    if (!const {'auto-accept', 'mandatory', 'worktree-only'}.contains(trimmed)) {
      _log.warning('Task ${task.id}: unknown reviewMode "$trimmed", using default');
      return null;
    }
    return trimmed;
  }

  TaskStatus get postCompletionStatus {
    return switch (reviewMode) {
      'auto-accept' => TaskStatus.accepted,
      'mandatory' => TaskStatus.review,
      'worktree-only' => needsWorktree ? TaskStatus.review : TaskStatus.accepted,
      _ => TaskStatus.review,
    };
  }

  bool get hasNeedsWorktreeDeclaration => task.configJson.containsKey(needsWorktreeKey);

  bool get needsWorktree => task.configJson[needsWorktreeKey] == true;

  Set<String>? get artifactExtensions {
    if (!task.configJson.containsKey('artifactExtensions')) return null;
    final raw = task.configJson['artifactExtensions'];
    if (raw is! List) {
      _log.warning('Task ${task.id}: malformed artifactExtensions in configJson, collecting no workspace files');
      return const {};
    }
    final extensions = <String>{};
    for (final value in raw) {
      if (value is! String || value.trim().isEmpty) {
        _log.warning('Task ${task.id}: malformed artifactExtensions in configJson, collecting no workspace files');
        return const {};
      }
      extensions.add(value.trim().toLowerCase());
    }
    return extensions;
  }

  String? get model => task.model;

  String? get effort => _trimmedString('effort');

  String? get securityProfile {
    if (!task.configJson.containsKey(securityProfileKey)) return null;
    final raw = task.configJson[securityProfileKey];
    if (raw is! String || raw.trim().isEmpty) {
      throw const ExecutionPolicyException(
        'Cannot run the task lane: securityProfile must be a non-empty string when declared.',
      );
    }
    return raw.trim();
  }

  String? get pushBackComment => _trimmedString('pushBackComment');

  String? get lastError {
    final raw = task.configJson['lastError'];
    return raw is String ? raw : null;
  }

  String? get continueSessionId => _trimmedString('_continueSessionId');

  String? get requiredInputPath => _trimmedString('requiredInputPath');

  String? _trimmedString(String key) {
    final raw = task.configJson[key];
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
