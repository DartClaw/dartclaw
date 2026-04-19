import 'package:dartclaw_models/dartclaw_models.dart' show TaskType;

import 'task.dart';
import 'task_artifact.dart';
import 'task_status.dart';

/// Minimal task service contract required by workflow execution.
abstract interface class WorkflowTaskService {
  /// Returns the task with [id], or null when missing.
  Future<Task?> get(String id);

  /// Creates a task.
  Future<Task> create({
    required String id,
    required String title,
    required String description,
    required TaskType type,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    String? createdBy,
    String? provider,
    String? agentExecutionId,
    String? projectId,
    int? maxTokens,
    String? workflowRunId,
    int? stepIndex,
    int maxRetries = 0,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
    String trigger = 'system',
  });

  /// Applies a lifecycle transition.
  Future<Task> transition(
    String taskId,
    TaskStatus newStatus, {
    DateTime? now,
    Map<String, dynamic>? configJson,
    String trigger = 'system',
  });

  /// Lists tasks with optional status/type filters.
  Future<List<Task>> list({TaskStatus? status, TaskType? type});

  /// Lists artifacts for the task with [taskId].
  Future<List<TaskArtifact>> listArtifacts(String taskId);
}
