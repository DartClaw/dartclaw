import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show ArtifactKind, Task, TaskArtifact, TaskLegacyRefusal, TaskRepository, TaskStatus;

import 'sqlite_execution_row_mappers.dart';

/// SQLite-backed task persistence for [Task] and [TaskArtifact].
class SqliteTaskRepository implements TaskRepository {
  /// Creates the repository against [_backend].
  new(this._backend);

  final DatabaseBackend _backend;

  static const _taskSelectColumns = '''
    t.id AS task_id,
    t.title AS task_title,
    t.description AS task_description,
    t.type AS task_type,
    t.status AS task_status,
    t.version AS task_version,
    t.goal_id AS task_goal_id,
    t.acceptance_criteria AS task_acceptance_criteria,
    t.config_json AS task_config_json,
    t.worktree_json AS task_worktree_json,
    t.created_at AS task_created_at,
    t.started_at AS task_started_at,
    t.completed_at AS task_completed_at,
    t.created_by AS task_created_by,
    t.agent_execution_id AS task_agent_execution_id,
    t.project_id AS task_project_id,
    t.workflow_run_id AS task_workflow_run_id,
    t.step_index AS task_step_index,
    t.max_retries AS task_max_retries,
    t.retry_count AS task_retry_count
  ''';

  static const _agentExecutionSelectColumns = '''
    ae.id AS ae_id,
    ae.session_id AS ae_session_id,
    ae.provider AS ae_provider,
    ae.model AS ae_model,
    ae.workspace_dir AS ae_workspace_dir,
    ae.container_json AS ae_container_json,
    ae.budget_tokens AS ae_budget_tokens,
    ae.harness_meta_json AS ae_harness_meta_json,
    ae.started_at AS ae_started_at,
    ae.completed_at AS ae_completed_at
  ''';

  static const _workflowStepExecutionSelectColumns = '''
    wse.task_id AS wse_task_id,
    wse.agent_execution_id AS wse_agent_execution_id,
    wse.workflow_run_id AS wse_workflow_run_id,
    wse.step_index AS wse_step_index,
    wse.step_id AS wse_step_id,
    wse.step_type AS wse_step_type,
    wse.git_json AS wse_git_json,
    wse.provider_session_id AS wse_provider_session_id,
    wse.structured_schema_json AS wse_structured_schema_json,
    wse.structured_output_json AS wse_structured_output_json,
    wse.follow_up_prompts_json AS wse_follow_up_prompts_json,
    wse.map_iteration_index AS wse_map_iteration_index,
    wse.map_iteration_total AS wse_map_iteration_total,
    wse.step_token_breakdown_json AS wse_step_token_breakdown_json
  ''';

  static const _joinedSelectClause =
      'SELECT $_taskSelectColumns, $_agentExecutionSelectColumns, $_workflowStepExecutionSelectColumns '
      'FROM tasks t '
      'LEFT JOIN agent_executions ae ON ae.id = t.agent_execution_id '
      'LEFT JOIN workflow_step_executions wse ON wse.task_id = t.id';

  @override
  Future<void> insert(Task task) async {
    await _upsertAgentExecution(task.agentExecution);
    final stmt = await _backend.prepare('''
      INSERT INTO tasks (
        id,
        title,
        description,
        type,
        status,
        version,
        goal_id,
        acceptance_criteria,
        config_json,
        worktree_json,
        created_at,
        started_at,
        completed_at,
        created_by,
        agent_execution_id,
        project_id,
        workflow_run_id,
        step_index,
        max_retries,
        retry_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      await stmt.execute([
        task.id,
        task.title,
        task.description,
        taskTypeStoragePlaceholder,
        task.status.name,
        1,
        task.goalId,
        task.acceptanceCriteria,
        _encodeJson(task.configJson),
        _encodeJsonNullable(task.worktreeJson),
        task.createdAt.toIso8601String(),
        task.startedAt?.toIso8601String(),
        task.completedAt?.toIso8601String(),
        task.createdBy,
        task.agentExecutionId,
        task.projectId,
        task.workflowRunId,
        task.stepIndex,
        task.maxRetries,
        task.retryCount,
      ]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<Task?> getById(String id) async {
    final stmt = await _backend.prepare('$_joinedSelectClause WHERE t.id = ?');
    try {
      final rows = await stmt.query([id]);
      return rows.isEmpty ? null : _taskFromJoinedRow(rows.first);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<List<Task>> list({TaskStatus? status}) async {
    final where = <String>[];
    final params = <Object?>[];
    if (status != null) {
      where.add('t.status = ?');
      params.add(status.name);
    }
    final buffer = StringBuffer(_joinedSelectClause);
    if (where.isNotEmpty) {
      buffer.write(' WHERE ${where.join(' AND ')}');
    }
    buffer.write(' ORDER BY t.created_at DESC, t.id DESC');

    final stmt = await _backend.prepare(buffer.toString());
    try {
      return (await stmt.query(params)).map(_taskFromJoinedRow).toList(growable: false);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<List<Task>> listByWorkflowRunIds(Iterable<String> runIds) async {
    final ids = runIds.toSet().toList(growable: false);
    if (ids.isEmpty) {
      return const [];
    }

    final placeholders = List.filled(ids.length, '?').join(', ');
    final stmt = await _backend.prepare(
      '$_joinedSelectClause WHERE t.workflow_run_id IN ($placeholders) ORDER BY t.created_at DESC, t.id DESC',
    );
    try {
      return (await stmt.query(ids)).map(_taskFromJoinedRow).toList(growable: false);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> update(Task task) async {
    await _upsertAgentExecution(task.agentExecution);
    final stmt = await _backend.prepare('''
      UPDATE tasks
      SET
        title = ?,
        description = ?,
        status = ?,
        version = version + 1,
        goal_id = ?,
        acceptance_criteria = ?,
        config_json = ?,
        worktree_json = ?,
        started_at = ?,
        completed_at = ?,
        agent_execution_id = ?,
        project_id = ?,
        workflow_run_id = ?,
        step_index = ?,
        max_retries = ?,
        retry_count = ?
      WHERE id = ? AND version = ?
    ''');
    try {
      final changed = await stmt.execute([
        task.title,
        task.description,
        task.status.name,
        task.goalId,
        task.acceptanceCriteria,
        _encodeJson(task.configJson),
        _encodeJsonNullable(task.worktreeJson),
        task.startedAt?.toIso8601String(),
        task.completedAt?.toIso8601String(),
        task.agentExecutionId,
        task.projectId,
        task.workflowRunId,
        task.stepIndex,
        task.maxRetries,
        task.retryCount,
        task.id,
        task.version,
      ]);
      if (changed == 0) {
        throw ArgumentError('Task not found: ${task.id}');
      }
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final stmt = await _backend.prepare('''
      UPDATE tasks
      SET
        status = ?,
        version = version + 1,
        config_json = ?,
        started_at = ?,
        completed_at = ?
      WHERE id = ? AND status = ? AND version = ?
    ''');
    try {
      final changed = await stmt.execute([
        task.status.name,
        _encodeJson(task.configJson),
        task.startedAt?.toIso8601String(),
        task.completedAt?.toIso8601String(),
        task.id,
        expectedStatus.name,
        task.version,
      ]);
      return changed > 0;
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    await _upsertAgentExecution(task.agentExecution);
    final stmt = await _backend.prepare('''
      UPDATE tasks
      SET
        title = ?,
        description = ?,
        acceptance_criteria = ?,
        config_json = ?,
        worktree_json = ?,
        agent_execution_id = ?,
        project_id = ?,
        retry_count = ?
      WHERE id = ? AND status = ?
    ''');
    try {
      final changed = await stmt.execute([
        task.title,
        task.description,
        task.acceptanceCriteria,
        _encodeJson(task.configJson),
        _encodeJsonNullable(task.worktreeJson),
        task.agentExecutionId,
        task.projectId,
        task.retryCount,
        task.id,
        expectedStatus.name,
      ]);
      return changed > 0;
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<bool> mergeConfigJsonIfStatus(
    String taskId,
    Map<String, dynamic> patch, {
    required TaskStatus expectedStatus,
  }) async {
    if (patch.isEmpty) {
      return true;
    }
    final stmt = await _backend.prepare('''
      UPDATE tasks
      SET config_json = json_patch(COALESCE(config_json, '{}'), ?)
      WHERE id = ? AND status = ?
    ''');
    try {
      final changed = await stmt.execute([_encodeJson(patch), taskId, expectedStatus.name]);
      return changed > 0;
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = await _backend.prepare('DELETE FROM tasks WHERE id = ?');
    try {
      final changed = await stmt.execute([id]);
      if (changed == 0) {
        throw ArgumentError('Task not found: $id');
      }
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> insertArtifact(TaskArtifact artifact) async {
    final stmt = await _backend.prepare('''
      INSERT INTO task_artifacts (id, task_id, name, kind, path, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    ''');
    try {
      await stmt.execute([
        artifact.id,
        artifact.taskId,
        artifact.name,
        artifact.kind.name,
        artifact.path,
        artifact.createdAt.toIso8601String(),
      ]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<TaskArtifact?> getArtifactById(String id) async {
    final stmt = await _backend.prepare('SELECT * FROM task_artifacts WHERE id = ?');
    try {
      final rows = await stmt.query([id]);
      return rows.isEmpty ? null : _artifactFromRow(rows.first);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<List<TaskArtifact>> listArtifactsByTask(String taskId) async {
    final stmt = await _backend.prepare('SELECT * FROM task_artifacts WHERE task_id = ? ORDER BY created_at ASC');
    try {
      return (await stmt.query([taskId])).map(_artifactFromRow).toList(growable: false);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> deleteArtifact(String id) async {
    final stmt = await _backend.prepare('DELETE FROM task_artifacts WHERE id = ?');
    try {
      await stmt.execute([id]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> dispose() async {
    // The composition root owns the shared backend lifecycle.
  }

  Task _taskFromJoinedRow(Map<String, Object?> row) {
    final configJson = _decodeJson(row['task_config_json'] as String);
    final legacyType = row['task_type'] as String;
    final legacyRefusal = switch (legacyType) {
      retiredResearchTaskType => TaskLegacyRefusal.securityProfileUndeclared,
      retiredCodingTaskType when configJson['needsWorktree'] is! bool => TaskLegacyRefusal.worktreeUndeclared,
      _ => null,
    };
    return Task(
      id: row['task_id'] as String,
      title: row['task_title'] as String,
      description: row['task_description'] as String,
      legacyRefusal: legacyRefusal,
      status: TaskStatus.values.byName(row['task_status'] as String),
      version: (row['task_version'] as int?) ?? 1,
      goalId: row['task_goal_id'] as String?,
      acceptanceCriteria: row['task_acceptance_criteria'] as String?,
      configJson: configJson,
      worktreeJson: _decodeJsonNullable(row['task_worktree_json'] as String?),
      createdAt: DateTime.parse(row['task_created_at'] as String),
      startedAt: sqliteDateTime(row['task_started_at']),
      completedAt: sqliteDateTime(row['task_completed_at']),
      createdBy: row['task_created_by'] as String?,
      agentExecutionId: row['task_agent_execution_id'] as String?,
      agentExecution: nullableAgentExecutionFromRow(row, prefix: 'ae_'),
      projectId: row['task_project_id'] as String?,
      workflowRunId: row['task_workflow_run_id'] as String?,
      stepIndex: row['task_step_index'] as int?,
      workflowStepExecution: nullableWorkflowStepExecutionFromRow(row, prefix: 'wse_'),
      maxRetries: (row['task_max_retries'] as int?) ?? 0,
      retryCount: (row['task_retry_count'] as int?) ?? 0,
    );
  }

  TaskArtifact _artifactFromRow(Map<String, Object?> row) {
    return TaskArtifact(
      id: row['id'] as String,
      taskId: row['task_id'] as String,
      name: row['name'] as String,
      kind: ArtifactKind.values.byName(row['kind'] as String),
      path: row['path'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  String _encodeJson(Map<String, dynamic> value) => jsonEncode(value);

  String? _encodeJsonNullable(Map<String, dynamic>? value) => value == null ? null : jsonEncode(value);

  Map<String, dynamic> _decodeJson(String value) => Map<String, dynamic>.from(jsonDecode(value) as Map);

  Map<String, dynamic>? _decodeJsonNullable(String? value) =>
      value == null ? null : Map<String, dynamic>.from(jsonDecode(value) as Map);

  Future<void> _upsertAgentExecution(AgentExecution? execution) async {
    if (execution == null) {
      return;
    }
    final stmt = await _backend.prepare('''
      INSERT INTO agent_executions (
        id,
        session_id,
        provider,
        model,
        workspace_dir,
        container_json,
        budget_tokens,
        harness_meta_json,
        started_at,
        completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        session_id = excluded.session_id,
        provider = excluded.provider,
        model = excluded.model,
        workspace_dir = excluded.workspace_dir,
        container_json = excluded.container_json,
        budget_tokens = excluded.budget_tokens,
        harness_meta_json = excluded.harness_meta_json,
        started_at = excluded.started_at,
        completed_at = excluded.completed_at
    ''');
    try {
      await stmt.execute([
        execution.id,
        execution.sessionId,
        execution.provider,
        execution.model,
        execution.workspaceDir,
        execution.containerJson,
        execution.budgetTokens,
        execution.harnessMetaJson,
        execution.startedAt?.toIso8601String(),
        execution.completedAt?.toIso8601String(),
      ]);
    } finally {
      await stmt.close();
    }
  }
}
