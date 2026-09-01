part of 'workflow_one_shot_runner.dart';

extension _WorkflowOneShotRunnerHelpers on WorkflowOneShotRunner {
  Future<Task> _writeWorkflowTokenBreakdownToTaskConfig(
    Task task, {
    required int inputTokens,
    required int cacheReadTokens,
    required int outputTokens,
  }) async {
    final current = await _tasks.get(task.id);
    if (current == null || current.status.terminal) return current ?? task;
    final patch = WorkflowTaskConfig.taskConfigTokenBreakdownPatch(
      inputTokensNew: cacheReadTokens > inputTokens ? 0 : inputTokens - cacheReadTokens,
      cacheReadTokens: cacheReadTokens,
      outputTokens: outputTokens,
    );
    return _tasks.mergeConfigJson(current.id, patch);
  }
}
