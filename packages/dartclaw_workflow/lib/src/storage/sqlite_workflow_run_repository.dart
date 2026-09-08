import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import '../workflow/workflow_run.dart' show WorkflowExecutionCursor, WorkflowRun, WorkflowWorktreeBinding;
import '../workflow/workflow_run_repository.dart' show WorkflowRunRepository;

/// SQLite-backed repository for workflow run persistence.
///
/// Requires a prepared tasks store shared with the other task and execution repositories.
class SqliteWorkflowRunRepository implements WorkflowRunRepository {
  final DatabaseBackend _backend;

  /// Creates the repository against a prepared [backend].
  new(this._backend);

  @override
  Future<void> insert(WorkflowRun run) async {
    final stmt = await _backend.prepare('''
      INSERT INTO workflow_runs (
        id, definition_name, status, context_json, variables_json,
        started_at, updated_at, completed_at, error_message,
        total_tokens, current_step_index, definition_json,
        execution_cursor_json, workflow_worktree_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      await stmt.execute([
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
        _encodeWorkflowWorktreeBindings(run.workflowWorktrees),
      ]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<WorkflowRun?> getById(String id) async {
    final stmt = await _backend.prepare('SELECT * FROM workflow_runs WHERE id = ?');
    try {
      final rows = await stmt.query([id]);
      return rows.isEmpty ? null : _workflowRunFromRow(rows.first);
    } finally {
      await stmt.close();
    }
  }

  @override
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

    final stmt = await _backend.prepare(buffer.toString());
    try {
      return (await stmt.query(params)).map(_workflowRunFromRow).toList(growable: false);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> update(WorkflowRun run) async {
    final stmt = await _backend.prepare('''
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
        workflow_worktree_json = COALESCE(?, workflow_worktree_json)
      WHERE id = ?
    ''');
    try {
      await stmt.execute([
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
        _encodeWorkflowWorktreeBindings(run.workflowWorktrees),
        run.id,
      ]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = await _backend.prepare('DELETE FROM workflow_runs WHERE id = ?');
    try {
      await stmt.execute([id]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> setWorktreeBinding(String runId, WorkflowWorktreeBinding binding) async {
    final existing = await getWorktreeBindings(runId);
    final updated = <WorkflowWorktreeBinding>[
      for (final candidate in existing)
        if (candidate.key != binding.key) candidate,
      binding,
    ];
    final stmt = await _backend.prepare('''
      UPDATE workflow_runs
      SET workflow_worktree_json = ?, updated_at = ?
      WHERE id = ?
    ''');
    try {
      final changed = await stmt.execute([
        _encodeWorkflowWorktreeBindings(updated),
        DateTime.now().toIso8601String(),
        runId,
      ]);
      if (changed == 0) {
        throw ArgumentError('Workflow run not found: $runId');
      }
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<WorkflowWorktreeBinding?> getWorktreeBinding(String runId) async {
    final bindings = await getWorktreeBindings(runId);
    return bindings.isEmpty ? null : bindings.last;
  }

  @override
  Future<List<WorkflowWorktreeBinding>> getWorktreeBindings(String runId) async {
    final stmt = await _backend.prepare('SELECT workflow_worktree_json FROM workflow_runs WHERE id = ?');
    try {
      final rows = await stmt.query([runId]);
      if (rows.isEmpty) return const [];
      return _decodeWorkflowWorktreeBindings(rows.first['workflow_worktree_json']);
    } finally {
      await stmt.close();
    }
  }

  WorkflowRun _workflowRunFromRow(Map<String, Object?> row) {
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

  String? _encodeWorkflowWorktreeBindings(List<WorkflowWorktreeBinding> bindings) =>
      bindings.isEmpty ? null : jsonEncode({'items': bindings.map((binding) => binding.toJson()).toList()});

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
