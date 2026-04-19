import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show Task, WorkflowStepExecution, WorkflowStepExecutionRepository;

/// Typed accessors for workflow-owned task execution metadata.
///
/// The `dartclaw_workflow` and `dartclaw_server` packages now communicate
/// workflow-only execution state through `WorkflowStepExecution` rows instead
/// of `_workflow*` entries in `Task.configJson`. Generic task settings such as
/// `model`, `allowedTools`, or `reviewMode` remain on the task; workflow-only
/// one-shot/session/git metadata lives behind this repository-backed seam.
abstract final class WorkflowTaskConfig {
  /// Returns the workflow step execution for [task], or null when this is not
  /// a workflow-spawned task with side-table metadata.
  static Future<WorkflowStepExecution?> read(Task task, WorkflowStepExecutionRepository repo) => repo.getByTaskId(task.id);

  /// Reads workflow follow-up prompts for one-shot execution.
  static Future<List<String>> readFollowUpPrompts(Task task, WorkflowStepExecutionRepository repo) async {
    final wse = await repo.getByTaskId(task.id);
    return wse?.followUpPrompts ?? const <String>[];
  }

  /// Reads the structured-output schema for the task, when present.
  static Future<Map<String, dynamic>?> readStructuredSchema(Task task, WorkflowStepExecutionRepository repo) async {
    final wse = await repo.getByTaskId(task.id);
    return wse?.structuredSchema;
  }

  /// Reads the structured-output payload for the task, when present.
  static Future<Map<String, dynamic>?> readStructuredOutputPayload(
    Task task,
    WorkflowStepExecutionRepository repo,
  ) async {
    final wse = await repo.getByTaskId(task.id);
    return wse?.structuredOutput;
  }

  /// Reads the provider-side session id captured for the task.
  static Future<String?> readProviderSessionId(Task task, WorkflowStepExecutionRepository repo) async {
    final wse = await repo.getByTaskId(task.id);
    return _trimmedOrNull(wse?.providerSessionId);
  }

  /// Reads the authored workflow step id for task-side reporting.
  static Future<String?> readWorkflowStepId(Task task, WorkflowStepExecutionRepository repo) async {
    final wse = await repo.getByTaskId(task.id);
    return _trimmedOrNull(wse?.stepId);
  }

  /// Reads the provider session id from a previously completed root step.
  static Future<String?> readContinueProviderSessionId(Task task, WorkflowStepExecutionRepository repo) =>
      readProviderSessionId(task, repo);

  /// Reads the new-input token count excluding cache reads.
  static Future<int> readInputTokensNew(Task task, WorkflowStepExecutionRepository repo) async {
    final breakdown = (await repo.getByTaskId(task.id))?.stepTokenBreakdown;
    return _readInt(breakdown, 'inputTokensNew');
  }

  /// Reads the cache-read token count.
  static Future<int> readCacheReadTokens(Task task, WorkflowStepExecutionRepository repo) async {
    final breakdown = (await repo.getByTaskId(task.id))?.stepTokenBreakdown;
    return _readInt(breakdown, 'cacheReadTokens');
  }

  /// Reads the output token count.
  static Future<int> readOutputTokens(Task task, WorkflowStepExecutionRepository repo) async {
    final breakdown = (await repo.getByTaskId(task.id))?.stepTokenBreakdown;
    return _readInt(breakdown, 'outputTokens');
  }

  /// Persists workflow follow-up prompts for one-shot execution.
  static Future<void> writeFollowUpPrompts(
    Task task,
    WorkflowStepExecutionRepository repo,
    List<String> prompts,
  ) async {
    await _update(repo, task.id, (wse) => wse.copyWith(followUpPromptsJson: jsonEncode(prompts)));
  }

  /// Persists the structured-output schema for the task.
  static Future<void> writeStructuredSchema(
    Task task,
    WorkflowStepExecutionRepository repo,
    Map<String, dynamic> schema,
  ) async {
    await _update(repo, task.id, (wse) => wse.copyWith(structuredSchemaJson: jsonEncode(schema)));
  }

  /// Persists the provider-side session id for the task.
  static Future<void> writeProviderSessionId(Task task, WorkflowStepExecutionRepository repo, String id) async {
    await _update(repo, task.id, (wse) => wse.copyWith(providerSessionId: _trimmedOrNull(id)));
  }

  /// Persists the structured-output payload for the task.
  static Future<void> writeStructuredOutputPayload(
    Task task,
    WorkflowStepExecutionRepository repo,
    Map<String, dynamic> payload,
  ) async {
    await _update(repo, task.id, (wse) => wse.copyWith(structuredOutputJson: jsonEncode(payload)));
  }

  /// Persists the provider session id on the workflow step row to support
  /// `continueSession` chains.
  static Future<void> writeContinueProviderSessionId(
    Task task,
    WorkflowStepExecutionRepository repo,
    String id,
  ) => writeProviderSessionId(task, repo, id);

  /// Persists per-step token breakdown.
  static Future<void> writeTokenBreakdown(
    Task task,
    WorkflowStepExecutionRepository repo, {
    required int inputTokensNew,
    required int cacheReadTokens,
    required int outputTokens,
  }) async {
    await _update(
      repo,
      task.id,
      (wse) => wse.copyWith(
        stepTokenBreakdownJson: jsonEncode({
          'inputTokensNew': inputTokensNew,
          'cacheReadTokens': cacheReadTokens,
          'outputTokens': outputTokens,
        }),
      ),
    );
  }

  static Future<void> _update(
    WorkflowStepExecutionRepository repo,
    String taskId,
    WorkflowStepExecution Function(WorkflowStepExecution current) mutate,
  ) async {
    final current = await repo.getByTaskId(taskId);
    if (current == null) {
      throw StateError('WorkflowStepExecution not found for task $taskId');
    }
    await repo.update(mutate(current));
  }

  static String? _trimmedOrNull(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _readInt(Map<String, dynamic>? payload, String key) {
    final value = payload?[key];
    return switch (value) {
      final int intValue when intValue >= 0 => intValue,
      final num numValue when numValue >= 0 => numValue.toInt(),
      _ => 0,
    };
  }
}
