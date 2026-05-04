import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show AgentExecution, ArtifactKind, Task, TaskArtifact, TaskRepository, TaskStatus, TaskType, WorkflowStepExecution;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed task persistence for [Task] and [TaskArtifact].
class SqliteTaskRepository implements TaskRepository {
  SqliteTaskRepository(this._db) {
    _initSchema();
  }

  final Database _db;

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
    wse.external_artifact_mount AS wse_external_artifact_mount,
    wse.map_iteration_index AS wse_map_iteration_index,
    wse.map_iteration_total AS wse_map_iteration_total,
    wse.step_token_breakdown_json AS wse_step_token_breakdown_json
  ''';

  static const _joinedSelectClause =
      'SELECT $_taskSelectColumns, $_agentExecutionSelectColumns, $_workflowStepExecutionSelectColumns '
      'FROM tasks t '
      'LEFT JOIN agent_executions ae ON ae.id = t.agent_execution_id '
      'LEFT JOIN workflow_step_executions wse ON wse.task_id = t.id';

  void _initSchema() {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA foreign_keys=ON');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS agent_executions (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT,
        provider TEXT,
        model TEXT,
        workspace_dir TEXT,
        container_json TEXT,
        budget_tokens INTEGER,
        harness_meta_json TEXT,
        started_at TEXT,
        completed_at TEXT
      )
    ''');
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
    _db.execute(_tasksTableSql(tableName: 'tasks'));
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(type)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status_type ON tasks(status, type)');

    _migrateLegacyTaskTableIfNeeded();
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_workflow_run_id ON tasks(workflow_run_id)');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS task_artifacts (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_task_artifacts_task_id ON task_artifacts(task_id)');
  }

  @override
  Future<void> insert(Task task) async {
    _upsertAgentExecution(task.agentExecution);
    final stmt = _db.prepare('''
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
      stmt.execute([
        task.id,
        task.title,
        task.description,
        task.type.name,
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
      stmt.close();
    }
  }

  @override
  Future<Task?> getById(String id) async {
    final stmt = _db.prepare('$_joinedSelectClause WHERE t.id = ?');
    try {
      final rows = stmt.select([id]);
      return rows.isEmpty ? null : _taskFromJoinedRow(rows.first);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) async {
    final where = <String>[];
    final params = <Object?>[];
    if (status != null) {
      where.add('t.status = ?');
      params.add(status.name);
    }
    if (type != null) {
      where.add('t.type = ?');
      params.add(type.name);
    }
    final buffer = StringBuffer(_joinedSelectClause);
    if (where.isNotEmpty) {
      buffer.write(' WHERE ${where.join(' AND ')}');
    }
    buffer.write(' ORDER BY t.created_at DESC, t.id DESC');

    final stmt = _db.prepare(buffer.toString());
    try {
      return stmt.select(params).map(_taskFromJoinedRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> update(Task task) async {
    _upsertAgentExecution(task.agentExecution);
    final stmt = _db.prepare('''
      UPDATE tasks
      SET
        title = ?,
        description = ?,
        type = ?,
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
      stmt.execute([
        task.title,
        task.description,
        task.type.name,
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
      if (_db.updatedRows == 0) {
        throw ArgumentError('Task not found: ${task.id}');
      }
    } finally {
      stmt.close();
    }
  }

  @override
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final stmt = _db.prepare('''
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
      stmt.execute([
        task.status.name,
        _encodeJson(task.configJson),
        task.startedAt?.toIso8601String(),
        task.completedAt?.toIso8601String(),
        task.id,
        expectedStatus.name,
        task.version,
      ]);
      return _db.updatedRows > 0;
    } finally {
      stmt.close();
    }
  }

  @override
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    _upsertAgentExecution(task.agentExecution);
    final stmt = _db.prepare('''
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
      stmt.execute([
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
      return _db.updatedRows > 0;
    } finally {
      stmt.close();
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
    final stmt = _db.prepare('''
      UPDATE tasks
      SET config_json = json_patch(COALESCE(config_json, '{}'), ?)
      WHERE id = ? AND status = ?
    ''');
    try {
      stmt.execute([_encodeJson(patch), taskId, expectedStatus.name]);
      return _db.updatedRows > 0;
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = _db.prepare('DELETE FROM tasks WHERE id = ?');
    try {
      stmt.execute([id]);
      if (_db.updatedRows == 0) {
        throw ArgumentError('Task not found: $id');
      }
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> insertArtifact(TaskArtifact artifact) async {
    final stmt = _db.prepare('''
      INSERT INTO task_artifacts (id, task_id, name, kind, path, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
        artifact.id,
        artifact.taskId,
        artifact.name,
        artifact.kind.name,
        artifact.path,
        artifact.createdAt.toIso8601String(),
      ]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<TaskArtifact?> getArtifactById(String id) async {
    final stmt = _db.prepare('SELECT * FROM task_artifacts WHERE id = ?');
    try {
      final rows = stmt.select([id]);
      return rows.isEmpty ? null : _artifactFromRow(rows.first);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<TaskArtifact>> listArtifactsByTask(String taskId) async {
    final stmt = _db.prepare('SELECT * FROM task_artifacts WHERE task_id = ? ORDER BY created_at ASC');
    try {
      return stmt.select([taskId]).map(_artifactFromRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> deleteArtifact(String id) async {
    final stmt = _db.prepare('DELETE FROM task_artifacts WHERE id = ?');
    try {
      stmt.execute([id]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> dispose() async {
    _db.close();
  }

  void _migrateLegacyTaskTableIfNeeded() {
    final columns = _db.select('PRAGMA table_info(tasks)').map((row) => row['name'] as String).toSet();
    final foreignKeys = _db.select('PRAGMA foreign_key_list(tasks)');
    final hasAgentExecutionForeignKey = foreignKeys.any(
      (row) => row['table'] == 'agent_executions' && row['from'] == 'agent_execution_id',
    );
    final needsMigration =
        columns.contains('session_id') ||
        columns.contains('provider') ||
        columns.contains('max_tokens') ||
        !columns.contains('project_id') ||
        !columns.contains('workflow_run_id') ||
        !columns.contains('step_index') ||
        !columns.contains('max_retries') ||
        !columns.contains('retry_count') ||
        !columns.contains('agent_execution_id') ||
        !hasAgentExecutionForeignKey;
    if (!needsMigration) {
      return;
    }

    _db.execute('BEGIN');
    try {
      if (columns.contains('session_id') || columns.contains('provider') || columns.contains('max_tokens')) {
        _db.execute('''
          INSERT INTO agent_executions (id, session_id, provider, model, budget_tokens, started_at, completed_at)
          SELECT
            'ae-' || t.id,
            ${columns.contains('session_id') ? 't.session_id' : 'NULL'},
            ${columns.contains('provider') ? 't.provider' : 'NULL'},
            json_extract(t.config_json, '\$.model'),
            ${columns.contains('max_tokens') ? 't.max_tokens' : 'NULL'},
            t.started_at,
            t.completed_at
          FROM tasks t
          WHERE ${columns.contains('agent_execution_id') ? 't.agent_execution_id IS NULL' : '1 = 1'}
            AND NOT EXISTS (SELECT 1 FROM agent_executions ae WHERE ae.id = 'ae-' || t.id)
        ''');
        _db.execute('''
          UPDATE tasks
          SET config_json = CASE
            WHEN json_type(config_json, '\$.model') IS NULL THEN config_json
            ELSE json_remove(config_json, '\$.model')
          END
        ''');
      }

      _db.execute(_tasksTableSql(tableName: 'tasks_v2'));
      _db.execute('''
        INSERT INTO tasks_v2 (
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
        )
        SELECT
          id,
          title,
          description,
          type,
          status,
          COALESCE(version, 1),
          goal_id,
          acceptance_criteria,
          config_json,
          worktree_json,
          created_at,
          started_at,
          completed_at,
          ${columns.contains('created_by') ? 'created_by' : 'NULL'},
          COALESCE(${columns.contains('agent_execution_id') ? 'agent_execution_id' : 'NULL'}, CASE
            WHEN EXISTS (SELECT 1 FROM agent_executions ae WHERE ae.id = 'ae-' || tasks.id) THEN 'ae-' || tasks.id
            ELSE NULL
          END),
          ${columns.contains('project_id') ? 'project_id' : 'NULL'},
          ${columns.contains('workflow_run_id') ? 'workflow_run_id' : 'NULL'},
          ${columns.contains('step_index') ? 'step_index' : 'NULL'},
          ${columns.contains('max_retries') ? 'max_retries' : '0'},
          ${columns.contains('retry_count') ? 'retry_count' : '0'}
        FROM tasks
      ''');
      _db.execute('DROP TABLE tasks');
      _db.execute('ALTER TABLE tasks_v2 RENAME TO tasks');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(type)');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status_type ON tasks(status, type)');
      _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_workflow_run_id ON tasks(workflow_run_id)');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Task _taskFromJoinedRow(Row row) {
    return Task(
      id: row['task_id'] as String,
      title: row['task_title'] as String,
      description: row['task_description'] as String,
      type: TaskType.values.byName(row['task_type'] as String),
      status: TaskStatus.values.byName(row['task_status'] as String),
      version: (row['task_version'] as int?) ?? 1,
      goalId: row['task_goal_id'] as String?,
      acceptanceCriteria: row['task_acceptance_criteria'] as String?,
      configJson: _decodeJson(row['task_config_json'] as String),
      worktreeJson: _decodeJsonNullable(row['task_worktree_json'] as String?),
      createdAt: DateTime.parse(row['task_created_at'] as String),
      startedAt: _decodeDateTime(row['task_started_at']),
      completedAt: _decodeDateTime(row['task_completed_at']),
      createdBy: row['task_created_by'] as String?,
      agentExecutionId: row['task_agent_execution_id'] as String?,
      agentExecution: _agentExecutionFromRow(row),
      projectId: row['task_project_id'] as String?,
      workflowRunId: row['task_workflow_run_id'] as String?,
      stepIndex: row['task_step_index'] as int?,
      workflowStepExecution: _workflowStepExecutionFromRow(row),
      maxRetries: (row['task_max_retries'] as int?) ?? 0,
      retryCount: (row['task_retry_count'] as int?) ?? 0,
    );
  }

  AgentExecution? _agentExecutionFromRow(Row row) {
    final id = row['ae_id'] as String?;
    if (id == null || id.isEmpty) {
      return null;
    }
    return AgentExecution(
      id: id,
      sessionId: row['ae_session_id'] as String?,
      provider: row['ae_provider'] as String?,
      model: row['ae_model'] as String?,
      workspaceDir: row['ae_workspace_dir'] as String?,
      containerJson: row['ae_container_json'] as String?,
      budgetTokens: row['ae_budget_tokens'] as int?,
      harnessMetaJson: row['ae_harness_meta_json'] as String?,
      startedAt: _decodeDateTime(row['ae_started_at']),
      completedAt: _decodeDateTime(row['ae_completed_at']),
    );
  }

  WorkflowStepExecution? _workflowStepExecutionFromRow(Row row) {
    final taskId = row['wse_task_id'] as String?;
    if (taskId == null || taskId.isEmpty) {
      return null;
    }
    return WorkflowStepExecution(
      taskId: taskId,
      agentExecutionId: row['wse_agent_execution_id'] as String,
      workflowRunId: row['wse_workflow_run_id'] as String,
      stepIndex: row['wse_step_index'] as int,
      stepId: row['wse_step_id'] as String,
      stepType: row['wse_step_type'] as String?,
      gitJson: row['wse_git_json'] as String?,
      providerSessionId: row['wse_provider_session_id'] as String?,
      structuredSchemaJson: row['wse_structured_schema_json'] as String?,
      structuredOutputJson: row['wse_structured_output_json'] as String?,
      followUpPromptsJson: row['wse_follow_up_prompts_json'] as String?,
      externalArtifactMount: row['wse_external_artifact_mount'] as String?,
      mapIterationIndex: row['wse_map_iteration_index'] as int?,
      mapIterationTotal: row['wse_map_iteration_total'] as int?,
      stepTokenBreakdownJson: row['wse_step_token_breakdown_json'] as String?,
    );
  }

  TaskArtifact _artifactFromRow(Row row) {
    return TaskArtifact(
      id: row['id'] as String,
      taskId: row['task_id'] as String,
      name: row['name'] as String,
      kind: ArtifactKind.values.byName(row['kind'] as String),
      path: row['path'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  DateTime? _decodeDateTime(Object? value) => value == null ? null : DateTime.parse(value as String);

  String _encodeJson(Map<String, dynamic> value) => jsonEncode(value);

  String? _encodeJsonNullable(Map<String, dynamic>? value) => value == null ? null : jsonEncode(value);

  Map<String, dynamic> _decodeJson(String value) => Map<String, dynamic>.from(jsonDecode(value) as Map);

  Map<String, dynamic>? _decodeJsonNullable(String? value) =>
      value == null ? null : Map<String, dynamic>.from(jsonDecode(value) as Map);

  String _tasksTableSql({required String tableName}) =>
      '''
    CREATE TABLE IF NOT EXISTS $tableName (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      type TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'draft',
      version INTEGER NOT NULL DEFAULT 1,
      goal_id TEXT,
      acceptance_criteria TEXT,
      config_json TEXT NOT NULL DEFAULT '{}',
      worktree_json TEXT,
      created_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      created_by TEXT,
      agent_execution_id TEXT REFERENCES agent_executions(id) ON DELETE RESTRICT,
      project_id TEXT,
      workflow_run_id TEXT,
      step_index INTEGER,
      max_retries INTEGER NOT NULL DEFAULT 0,
      retry_count INTEGER NOT NULL DEFAULT 0
    )
  ''';

  void _upsertAgentExecution(AgentExecution? execution) {
    if (execution == null) {
      return;
    }
    final stmt = _db.prepare('''
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
      stmt.execute([
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
      stmt.close();
    }
  }
}
