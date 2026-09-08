import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'sqlite_execution_row_mappers.dart';

/// SQLite-backed persistence for [WorkflowStepExecution].
class SqliteWorkflowStepExecutionRepository implements WorkflowStepExecutionRepository {
  final DatabaseBackend _backend;

  /// Creates the repository against a prepared [backend].
  new(this._backend);

  @override
  Future<void> create(WorkflowStepExecution execution) async {
    final stmt = await _backend.prepare('''
      INSERT INTO workflow_step_executions (
        task_id,
        agent_execution_id,
        workflow_run_id,
        step_index,
        step_id,
        step_type,
        git_json,
        provider_session_id,
        structured_schema_json,
        structured_output_json,
        follow_up_prompts_json,
        map_iteration_index,
        map_iteration_total,
        step_token_breakdown_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      await stmt.execute([
        execution.taskId,
        execution.agentExecutionId,
        execution.workflowRunId,
        execution.stepIndex,
        execution.stepId,
        execution.stepType,
        execution.gitJson,
        execution.providerSessionId,
        execution.structuredSchemaJson,
        execution.structuredOutputJson,
        execution.followUpPromptsJson,
        execution.mapIterationIndex,
        execution.mapIterationTotal,
        execution.stepTokenBreakdownJson,
      ]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<WorkflowStepExecution?> getByTaskId(String taskId) async {
    final stmt = await _backend.prepare('SELECT * FROM workflow_step_executions WHERE task_id = ?');
    try {
      final rows = await stmt.query([taskId]);
      return rows.isEmpty ? null : workflowStepExecutionFromRow(rows.first);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<List<WorkflowStepExecution>> listByRunId(String workflowRunId) async {
    final stmt = await _backend.prepare('''
      SELECT *
      FROM workflow_step_executions
      WHERE workflow_run_id = ?
      ORDER BY step_index ASC, task_id ASC
    ''');
    try {
      return (await stmt.query([workflowRunId])).map(workflowStepExecutionFromRow).toList(growable: false);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> update(WorkflowStepExecution execution) async {
    final stmt = await _backend.prepare('''
      UPDATE workflow_step_executions
      SET
        agent_execution_id = ?,
        workflow_run_id = ?,
        step_index = ?,
        step_id = ?,
        step_type = ?,
        git_json = ?,
        provider_session_id = ?,
        structured_schema_json = ?,
        structured_output_json = ?,
        follow_up_prompts_json = ?,
        map_iteration_index = ?,
        map_iteration_total = ?,
        step_token_breakdown_json = ?
      WHERE task_id = ?
    ''');
    try {
      final changed = await stmt.execute([
        execution.agentExecutionId,
        execution.workflowRunId,
        execution.stepIndex,
        execution.stepId,
        execution.stepType,
        execution.gitJson,
        execution.providerSessionId,
        execution.structuredSchemaJson,
        execution.structuredOutputJson,
        execution.followUpPromptsJson,
        execution.mapIterationIndex,
        execution.mapIterationTotal,
        execution.stepTokenBreakdownJson,
        execution.taskId,
      ]);
      if (changed == 0) {
        throw ArgumentError('WorkflowStepExecution not found: ${execution.taskId}');
      }
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> delete(String taskId) async {
    final stmt = await _backend.prepare('DELETE FROM workflow_step_executions WHERE task_id = ?');
    try {
      await stmt.execute([taskId]);
    } finally {
      await stmt.close();
    }
  }
}
