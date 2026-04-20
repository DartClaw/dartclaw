import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show WorkflowExecutionCursor, WorkflowRun, WorkflowRunStatus, WorkflowWorktreeBinding;
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed repository for workflow run persistence.
///
/// Shares the tasks database ([Database]) with [SqliteTaskRepository].
/// Uses CREATE TABLE IF NOT EXISTS for idempotent schema initialization.
class SqliteWorkflowRunRepository {
  static final _log = Logger('SqliteWorkflowRunRepository');
  final Database _db;

  SqliteWorkflowRunRepository(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_runs (
        id TEXT PRIMARY KEY,
        definition_name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        context_json TEXT NOT NULL DEFAULT '{}',
        variables_json TEXT NOT NULL DEFAULT '{}',
        started_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        error_message TEXT,
        total_tokens INTEGER NOT NULL DEFAULT 0,
        current_step_index INTEGER NOT NULL DEFAULT 0,
        definition_json TEXT NOT NULL DEFAULT '{}',
        execution_cursor_json TEXT,
        workflow_worktree_json TEXT,
        current_loop_id TEXT,
        current_loop_iteration INTEGER
      )
    ''');
    final columns = _db.select('PRAGMA table_info(workflow_runs)').map((row) => row['name'] as String).toSet();
    if (!columns.contains('execution_cursor_json')) {
      _db.execute('ALTER TABLE workflow_runs ADD COLUMN execution_cursor_json TEXT');
    }
    if (!columns.contains('workflow_worktree_json')) {
      _db.execute('ALTER TABLE workflow_runs ADD COLUMN workflow_worktree_json TEXT');
    }
    _db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_runs_status ON workflow_runs(status)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_runs_definition ON workflow_runs(definition_name)');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS workflow_run_migrations (
        name TEXT PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
    ''');
    _migrateLegacyPausedStatuses();
  }

  void _migrateLegacyPausedStatuses() {
    const migrationName = 's36_awaiting_approval_status_split';
    final existing = _db.select('SELECT 1 FROM workflow_run_migrations WHERE name = ? LIMIT 1', [migrationName]);
    if (existing.isNotEmpty) return;

    _db.execute('BEGIN');
    try {
      final pausedRows = _db.select('SELECT id, context_json FROM workflow_runs WHERE status = ?', [
        WorkflowRunStatus.paused.name,
      ]);

      var awaitingApprovalCount = 0;
      var failedCount = 0;
      final updateStmt = _db.prepare('UPDATE workflow_runs SET status = ? WHERE id = ?');
      try {
        for (final row in pausedRows) {
          final id = row['id'] as String;
          final contextJson = _decodeJson(row['context_json'] as String);
          final hasPendingApproval = contextJson['_approval.pending.stepId'] is String;
          final nextStatus = hasPendingApproval
              ? WorkflowRunStatus.awaitingApproval.name
              : WorkflowRunStatus.failed.name;
          updateStmt.execute([nextStatus, id]);
          if (hasPendingApproval) {
            awaitingApprovalCount++;
          } else {
            failedCount++;
          }
        }
      } finally {
        updateStmt.close();
      }

      _db.execute('INSERT INTO workflow_run_migrations (name, applied_at) VALUES (?, ?)', [
        migrationName,
        DateTime.now().toIso8601String(),
      ]);
      _db.execute('COMMIT');
      _log.info(
        'Applied workflow-run status migration $migrationName '
        '(awaitingApproval=$awaitingApprovalCount, failed=$failedCount)',
      );
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> insert(WorkflowRun run) async {
    final stmt = _db.prepare('''
      INSERT INTO workflow_runs (
        id, definition_name, status, context_json, variables_json,
        started_at, updated_at, completed_at, error_message,
        total_tokens, current_step_index, definition_json,
        execution_cursor_json, workflow_worktree_json, current_loop_id, current_loop_iteration
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
        run.id,
        run.definitionName,
        run.status.name,
        _encodeJson(run.contextJson),
        _encodeJson(run.variablesJson),
        run.startedAt.toIso8601String(),
        run.updatedAt.toIso8601String(),
        run.completedAt?.toIso8601String(),
        run.errorMessage,
        run.totalTokens,
        run.currentStepIndex,
        _encodeJson(run.definitionJson),
        _encodeJsonNullable(run.executionCursor?.toJson()),
        _encodeJsonNullable(
          run.workflowWorktrees.isEmpty
              ? null
              : {'items': run.workflowWorktrees.map((binding) => binding.toJson()).toList()},
        ),
        run.currentLoopId,
        run.currentLoopIteration,
      ]);
    } finally {
      stmt.close();
    }
  }

  Future<WorkflowRun?> getById(String id) async {
    final stmt = _db.prepare('SELECT * FROM workflow_runs WHERE id = ?');
    try {
      final rows = stmt.select([id]);
      return rows.isEmpty ? null : _workflowRunFromRow(rows.first);
    } finally {
      stmt.close();
    }
  }

  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) async {
    final where = <String>[];
    final params = <Object?>[];
    if (status != null) {
      where.add('status = ?');
      params.add(status.name);
    }
    if (definitionName != null) {
      where.add('definition_name = ?');
      params.add(definitionName);
    }
    final buffer = StringBuffer('SELECT * FROM workflow_runs');
    if (where.isNotEmpty) {
      buffer.write(' WHERE ${where.join(' AND ')}');
    }
    buffer.write(' ORDER BY started_at DESC, id DESC');

    final stmt = _db.prepare(buffer.toString());
    try {
      return stmt.select(params).map(_workflowRunFromRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  Future<void> update(WorkflowRun run) async {
    final stmt = _db.prepare('''
      UPDATE workflow_runs
      SET
        status = ?,
        context_json = ?,
        variables_json = ?,
        updated_at = ?,
        completed_at = ?,
        error_message = ?,
        total_tokens = ?,
        current_step_index = ?,
        definition_json = ?,
        execution_cursor_json = ?,
        workflow_worktree_json = COALESCE(?, workflow_worktree_json),
        current_loop_id = ?,
        current_loop_iteration = ?
      WHERE id = ?
    ''');
    try {
      stmt.execute([
        run.status.name,
        _encodeJson(run.contextJson),
        _encodeJson(run.variablesJson),
        run.updatedAt.toIso8601String(),
        run.completedAt?.toIso8601String(),
        run.errorMessage,
        run.totalTokens,
        run.currentStepIndex,
        _encodeJson(run.definitionJson),
        _encodeJsonNullable(run.executionCursor?.toJson()),
        _encodeJsonNullable(
          run.workflowWorktrees.isEmpty
              ? null
              : {'items': run.workflowWorktrees.map((binding) => binding.toJson()).toList()},
        ),
        run.currentLoopId,
        run.currentLoopIteration,
        run.id,
      ]);
    } finally {
      stmt.close();
    }
  }

  Future<void> delete(String id) async {
    final stmt = _db.prepare('DELETE FROM workflow_runs WHERE id = ?');
    try {
      stmt.execute([id]);
    } finally {
      stmt.close();
    }
  }

  Future<void> setWorktreeBinding(String runId, WorkflowWorktreeBinding binding) async {
    final existing = await getWorktreeBindings(runId);
    final updated = <WorkflowWorktreeBinding>[
      for (final candidate in existing)
        if (candidate.key != binding.key) candidate,
      binding,
    ];
    final stmt = _db.prepare('''
      UPDATE workflow_runs
      SET workflow_worktree_json = ?, updated_at = ?
      WHERE id = ?
    ''');
    try {
      stmt.execute([
        jsonEncode({'items': updated.map((candidate) => candidate.toJson()).toList()}),
        DateTime.now().toIso8601String(),
        runId,
      ]);
      if (_db.updatedRows == 0) {
        throw ArgumentError('Workflow run not found: $runId');
      }
    } finally {
      stmt.close();
    }
  }

  Future<WorkflowWorktreeBinding?> getWorktreeBinding(String runId) async {
    final bindings = await getWorktreeBindings(runId);
    return bindings.isEmpty ? null : bindings.last;
  }

  Future<List<WorkflowWorktreeBinding>> getWorktreeBindings(String runId) async {
    final stmt = _db.prepare('SELECT workflow_worktree_json FROM workflow_runs WHERE id = ?');
    try {
      final rows = stmt.select([runId]);
      if (rows.isEmpty) return const [];
      final json = _decodeJsonNullable(rows.first['workflow_worktree_json']);
      if (json == null) return const [];
      final items = json['items'];
      if (items is List) {
        return items
            .map((item) => WorkflowWorktreeBinding.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(growable: false);
      }
      return [WorkflowWorktreeBinding.fromJson(json)];
    } finally {
      stmt.close();
    }
  }

  WorkflowRun _workflowRunFromRow(Row row) {
    return WorkflowRun(
      id: row['id'] as String,
      definitionName: row['definition_name'] as String,
      status: WorkflowRunStatus.values.byName(row['status'] as String),
      contextJson: _decodeJson(row['context_json'] as String),
      variablesJson: _decodeStringMap(row['variables_json'] as String),
      startedAt: DateTime.parse(row['started_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      completedAt: _decodeDateTime(row['completed_at']),
      errorMessage: row['error_message'] as String?,
      totalTokens: (row['total_tokens'] as int?) ?? 0,
      currentStepIndex: (row['current_step_index'] as int?) ?? 0,
      definitionJson: _decodeJson(row['definition_json'] as String),
      executionCursor: _decodeExecutionCursor(row['execution_cursor_json']),
      workflowWorktrees: _decodeWorkflowWorktreeBindings(row['workflow_worktree_json']),
      currentLoopId: row['current_loop_id'] as String?,
      currentLoopIteration: row['current_loop_iteration'] as int?,
    );
  }

  DateTime? _decodeDateTime(Object? value) => value == null ? null : DateTime.parse(value as String);

  String _encodeJson(Map<dynamic, dynamic> value) => jsonEncode(value);

  String? _encodeJsonNullable(Map<dynamic, dynamic>? value) => value == null ? null : jsonEncode(value);

  Map<String, dynamic> _decodeJson(String value) => Map<String, dynamic>.from(jsonDecode(value) as Map);

  Map<String, dynamic>? _decodeJsonNullable(Object? value) =>
      value == null ? null : Map<String, dynamic>.from(jsonDecode(value as String) as Map);

  WorkflowExecutionCursor? _decodeExecutionCursor(Object? value) {
    final json = _decodeJsonNullable(value);
    return json == null ? null : WorkflowExecutionCursor.fromJson(json);
  }

  List<WorkflowWorktreeBinding> _decodeWorkflowWorktreeBindings(Object? value) {
    final json = _decodeJsonNullable(value);
    if (json == null) return const [];
    final items = json['items'];
    if (items is List) {
      return items
          .map((item) => WorkflowWorktreeBinding.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList(growable: false);
    }
    return [WorkflowWorktreeBinding.fromJson(json)];
  }

  Map<String, String> _decodeStringMap(String value) => Map<String, String>.from(jsonDecode(value) as Map);
}
