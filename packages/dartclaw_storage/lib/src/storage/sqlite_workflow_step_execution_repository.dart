import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowStepExecution, WorkflowStepExecutionRepository;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed persistence for [WorkflowStepExecution].
class SqliteWorkflowStepExecutionRepository implements WorkflowStepExecutionRepository {
  final Database _db;

  SqliteWorkflowStepExecutionRepository(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('PRAGMA foreign_keys=ON');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_step_executions (
        task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
        agent_execution_id TEXT NOT NULL REFERENCES agent_executions(id),
        workflow_run_id TEXT NOT NULL,
        step_index INTEGER NOT NULL,
        step_id TEXT NOT NULL,
        step_type TEXT,
        git_json TEXT,
        provider_session_id TEXT,
        structured_schema_json TEXT,
        structured_output_json TEXT,
        follow_up_prompts_json TEXT,
        external_artifact_mount TEXT,
        map_iteration_index INTEGER,
        map_iteration_total INTEGER,
        step_token_breakdown_json TEXT
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_wse_run_step ON workflow_step_executions(workflow_run_id, step_index)');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_wse_agent_execution ON workflow_step_executions(agent_execution_id)',
    );
  }

  @override
  Future<void> create(WorkflowStepExecution execution) async {
    final stmt = _db.prepare('''
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
        external_artifact_mount,
        map_iteration_index,
        map_iteration_total,
        step_token_breakdown_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
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
        execution.externalArtifactMount,
        execution.mapIterationIndex,
        execution.mapIterationTotal,
        execution.stepTokenBreakdownJson,
      ]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<WorkflowStepExecution?> getByTaskId(String taskId) async {
    final stmt = _db.prepare('SELECT * FROM workflow_step_executions WHERE task_id = ?');
    try {
      final rows = stmt.select([taskId]);
      return rows.isEmpty ? null : _executionFromRow(rows.first);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<WorkflowStepExecution>> listByRunId(String workflowRunId) async {
    final stmt = _db.prepare('''
      SELECT *
      FROM workflow_step_executions
      WHERE workflow_run_id = ?
      ORDER BY step_index ASC, task_id ASC
    ''');
    try {
      return stmt.select([workflowRunId]).map(_executionFromRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> update(WorkflowStepExecution execution) async {
    final stmt = _db.prepare('''
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
        external_artifact_mount = ?,
        map_iteration_index = ?,
        map_iteration_total = ?,
        step_token_breakdown_json = ?
      WHERE task_id = ?
    ''');
    try {
      stmt.execute([
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
        execution.externalArtifactMount,
        execution.mapIterationIndex,
        execution.mapIterationTotal,
        execution.stepTokenBreakdownJson,
        execution.taskId,
      ]);
      if (_db.updatedRows == 0) {
        throw ArgumentError('WorkflowStepExecution not found: ${execution.taskId}');
      }
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> delete(String taskId) async {
    final stmt = _db.prepare('DELETE FROM workflow_step_executions WHERE task_id = ?');
    try {
      stmt.execute([taskId]);
    } finally {
      stmt.close();
    }
  }

  WorkflowStepExecution _executionFromRow(Row row) => WorkflowStepExecution(
    taskId: row['task_id'] as String,
    agentExecutionId: row['agent_execution_id'] as String,
    workflowRunId: row['workflow_run_id'] as String,
    stepIndex: row['step_index'] as int,
    stepId: row['step_id'] as String,
    stepType: row['step_type'] as String?,
    gitJson: row['git_json'] as String?,
    providerSessionId: row['provider_session_id'] as String?,
    structuredSchemaJson: row['structured_schema_json'] as String?,
    structuredOutputJson: row['structured_output_json'] as String?,
    followUpPromptsJson: row['follow_up_prompts_json'] as String?,
    externalArtifactMount: row['external_artifact_mount'] as String?,
    mapIterationIndex: row['map_iteration_index'] as int?,
    mapIterationTotal: row['map_iteration_total'] as int?,
    stepTokenBreakdownJson: row['step_token_breakdown_json'] as String?,
  );
}
