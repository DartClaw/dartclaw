import 'dart:async';

import 'workflow_step_execution.dart';

/// Storage-agnostic contract for [WorkflowStepExecution] persistence.
abstract class WorkflowStepExecutionRepository {
  /// Inserts a new workflow step execution.
  Future<void> create(WorkflowStepExecution execution);

  /// Returns the execution for [taskId], or null when missing.
  Future<WorkflowStepExecution?> getByTaskId(String taskId);

  /// Lists workflow step executions for a run ordered by step then task id.
  Future<List<WorkflowStepExecution>> listByRunId(String workflowRunId);

  /// Persists an update to an existing execution.
  Future<void> update(WorkflowStepExecution execution);

  /// Deletes an execution by task id.
  Future<void> delete(String taskId);
}
