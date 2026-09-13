import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show AgentExecutionStatusChangedEvent, EventBus;

import 'sqlite_execution_row_mappers.dart';

/// SQLite-backed persistence for [AgentExecution].
class SqliteAgentExecutionRepository implements AgentExecutionRepository {
  final DatabaseBackend _backend;
  final EventBus? _eventBus;

  /// Creates the repository against a prepared [backend].
  new(this._backend, {EventBus? eventBus}) : _eventBus = eventBus;

  @override
  Future<void> create(AgentExecution execution) async {
    final stmt = await _backend.prepare('''
      INSERT INTO agent_executions (
        id, session_id, provider, model, workspace_dir, container_json,
        budget_tokens, harness_meta_json, started_at, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

  @override
  Future<AgentExecution?> get(String id) async {
    final stmt = await _backend.prepare('SELECT * FROM agent_executions WHERE id = ?');
    try {
      final rows = await stmt.query([id]);
      return rows.isEmpty ? null : agentExecutionFromRow(rows.first);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<List<AgentExecution>> list({String? sessionId, String? provider}) async {
    final where = <String>[];
    final params = <Object?>[];
    if (sessionId != null) {
      where.add('session_id = ?');
      params.add(sessionId);
    }
    if (provider != null) {
      where.add('provider = ?');
      params.add(provider);
    }

    final buffer = StringBuffer('SELECT * FROM agent_executions');
    if (where.isNotEmpty) {
      buffer.write(' WHERE ${where.join(' AND ')}');
    }
    buffer.write(' ORDER BY started_at DESC, id DESC');

    final stmt = await _backend.prepare(buffer.toString());
    try {
      return (await stmt.query(params)).map(agentExecutionFromRow).toList(growable: false);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> update(AgentExecution execution, {String trigger = 'system', DateTime? timestamp}) async {
    final previous = await get(execution.id);
    final stmt = await _backend.prepare('''
      UPDATE agent_executions
      SET
        session_id = ?,
        provider = ?,
        model = ?,
        workspace_dir = ?,
        container_json = ?,
        budget_tokens = ?,
        harness_meta_json = ?,
        started_at = ?,
        completed_at = ?
      WHERE id = ?
    ''');
    try {
      final changed = await stmt.execute([
        execution.sessionId,
        execution.provider,
        execution.model,
        execution.workspaceDir,
        execution.containerJson,
        execution.budgetTokens,
        execution.harnessMetaJson,
        execution.startedAt?.toIso8601String(),
        execution.completedAt?.toIso8601String(),
        execution.id,
      ]);
      if (changed == 0) {
        throw ArgumentError('AgentExecution not found: ${execution.id}');
      }
      final oldStatus = _statusOf(previous);
      final newStatus = _statusOf(execution);
      if (oldStatus != newStatus) {
        _eventBus?.fire(
          AgentExecutionStatusChangedEvent(
            agentExecutionId: execution.id,
            oldStatus: oldStatus,
            newStatus: newStatus,
            trigger: trigger,
            timestamp: timestamp ?? DateTime.now(),
          ),
        );
      }
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = await _backend.prepare('DELETE FROM agent_executions WHERE id = ?');
    try {
      await stmt.execute([id]);
    } finally {
      await stmt.close();
    }
  }

  String _statusOf(AgentExecution? execution) {
    if (execution == null) return 'missing';
    if (execution.completedAt != null) return 'completed';
    if (execution.startedAt != null) return 'running';
    return 'queued';
  }
}
