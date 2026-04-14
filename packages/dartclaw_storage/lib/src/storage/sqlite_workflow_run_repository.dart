import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowExecutionCursor, WorkflowRun, WorkflowRunStatus;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed repository for workflow run persistence.
///
/// Shares the tasks database ([Database]) with [SqliteTaskRepository].
/// Uses CREATE TABLE IF NOT EXISTS for idempotent schema initialization.
class SqliteWorkflowRunRepository {
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
        current_loop_id TEXT,
        current_loop_iteration INTEGER
      )
    ''');
    final columns = _db.select('PRAGMA table_info(workflow_runs)').map((row) => row['name'] as String).toSet();
    if (!columns.contains('execution_cursor_json')) {
      _db.execute('ALTER TABLE workflow_runs ADD COLUMN execution_cursor_json TEXT');
    }
    _db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_runs_status ON workflow_runs(status)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_workflow_runs_definition ON workflow_runs(definition_name)');
  }

  Future<void> insert(WorkflowRun run) async {
    final stmt = _db.prepare('''
      INSERT INTO workflow_runs (
        id, definition_name, status, context_json, variables_json,
        started_at, updated_at, completed_at, error_message,
        total_tokens, current_step_index, definition_json,
        execution_cursor_json, current_loop_id, current_loop_iteration
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

  Map<String, String> _decodeStringMap(String value) => Map<String, String>.from(jsonDecode(value) as Map);
}
