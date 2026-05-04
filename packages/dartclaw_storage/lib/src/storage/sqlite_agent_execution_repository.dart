import 'package:dartclaw_core/dartclaw_core.dart'
    show AgentExecution, AgentExecutionRepository, AgentExecutionStatusChangedEvent, EventBus;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed persistence for [AgentExecution].
class SqliteAgentExecutionRepository implements AgentExecutionRepository {
  final Database _db;
  final EventBus? _eventBus;

  SqliteAgentExecutionRepository(this._db, {EventBus? eventBus}) : _eventBus = eventBus {
    _initSchema();
  }

  void _initSchema() {
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
    _db.execute('CREATE INDEX IF NOT EXISTS idx_agent_executions_session_id ON agent_executions(session_id)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_agent_executions_provider ON agent_executions(provider)');
  }

  @override
  Future<void> create(AgentExecution execution) async {
    final stmt = _db.prepare('''
      INSERT INTO agent_executions (
        id, session_id, provider, model, workspace_dir, container_json,
        budget_tokens, harness_meta_json, started_at, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

  @override
  Future<AgentExecution?> get(String id) async {
    final stmt = _db.prepare('SELECT * FROM agent_executions WHERE id = ?');
    try {
      final rows = stmt.select([id]);
      return rows.isEmpty ? null : _executionFromRow(rows.first);
    } finally {
      stmt.close();
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

    final stmt = _db.prepare(buffer.toString());
    try {
      return stmt.select(params).map(_executionFromRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> update(AgentExecution execution, {String trigger = 'system', DateTime? timestamp}) async {
    final previous = await get(execution.id);
    final stmt = _db.prepare('''
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
      stmt.execute([
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
      if (_db.updatedRows == 0) {
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
      stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = _db.prepare('DELETE FROM agent_executions WHERE id = ?');
    try {
      stmt.execute([id]);
    } finally {
      stmt.close();
    }
  }

  AgentExecution _executionFromRow(Row row) {
    return AgentExecution(
      id: row['id'] as String,
      sessionId: row['session_id'] as String?,
      provider: row['provider'] as String?,
      model: row['model'] as String?,
      workspaceDir: row['workspace_dir'] as String?,
      containerJson: row['container_json'] as String?,
      budgetTokens: row['budget_tokens'] as int?,
      harnessMetaJson: row['harness_meta_json'] as String?,
      startedAt: _decodeDateTime(row['started_at']),
      completedAt: _decodeDateTime(row['completed_at']),
    );
  }

  DateTime? _decodeDateTime(Object? value) => value == null ? null : DateTime.parse(value as String);

  String _statusOf(AgentExecution? execution) {
    if (execution == null) return 'missing';
    if (execution.completedAt != null) return 'completed';
    if (execution.startedAt != null) return 'running';
    return 'queued';
  }
}
