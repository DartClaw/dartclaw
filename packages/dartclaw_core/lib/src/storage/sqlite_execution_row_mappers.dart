import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';

/// Hydrates an agent execution from unprefixed or [prefix]-aliased columns.
AgentExecution agentExecutionFromRow(Row row, {String prefix = ''}) => AgentExecution(
  id: row['${prefix}id'] as String,
  sessionId: row['${prefix}session_id'] as String?,
  provider: row['${prefix}provider'] as String?,
  model: row['${prefix}model'] as String?,
  workspaceDir: row['${prefix}workspace_dir'] as String?,
  containerJson: row['${prefix}container_json'] as String?,
  budgetTokens: row['${prefix}budget_tokens'] as int?,
  harnessMetaJson: row['${prefix}harness_meta_json'] as String?,
  startedAt: sqliteDateTime(row['${prefix}started_at']),
  completedAt: sqliteDateTime(row['${prefix}completed_at']),
);

/// Hydrates a prefixed agent execution, or returns null for an empty left join.
AgentExecution? nullableAgentExecutionFromRow(Row row, {required String prefix}) {
  final id = row['${prefix}id'] as String?;
  return id == null || id.isEmpty ? null : agentExecutionFromRow(row, prefix: prefix);
}

/// Hydrates a workflow step execution from unprefixed or [prefix]-aliased columns.
WorkflowStepExecution workflowStepExecutionFromRow(Row row, {String prefix = ''}) => WorkflowStepExecution(
  taskId: row['${prefix}task_id'] as String,
  agentExecutionId: row['${prefix}agent_execution_id'] as String,
  workflowRunId: row['${prefix}workflow_run_id'] as String,
  stepIndex: row['${prefix}step_index'] as int,
  stepId: row['${prefix}step_id'] as String,
  stepType: row['${prefix}step_type'] as String?,
  gitJson: row['${prefix}git_json'] as String?,
  providerSessionId: row['${prefix}provider_session_id'] as String?,
  structuredSchemaJson: row['${prefix}structured_schema_json'] as String?,
  structuredOutputJson: row['${prefix}structured_output_json'] as String?,
  followUpPromptsJson: row['${prefix}follow_up_prompts_json'] as String?,
  mapIterationIndex: row['${prefix}map_iteration_index'] as int?,
  mapIterationTotal: row['${prefix}map_iteration_total'] as int?,
  stepTokenBreakdownJson: row['${prefix}step_token_breakdown_json'] as String?,
);

/// Hydrates a prefixed workflow step execution, or returns null for an empty left join.
WorkflowStepExecution? nullableWorkflowStepExecutionFromRow(Row row, {required String prefix}) {
  final taskId = row['${prefix}task_id'] as String?;
  return taskId == null || taskId.isEmpty ? null : workflowStepExecutionFromRow(row, prefix: prefix);
}

/// Parses a persisted SQLite timestamp, preserving null values.
DateTime? sqliteDateTime(Object? value) => value == null ? null : DateTime.parse(value as String);
