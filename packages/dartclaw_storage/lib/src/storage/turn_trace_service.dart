import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show TurnTrace, TurnTraceSummary, ToolCallRecord;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed persistence for turn traces.
///
/// Shares the same [Database] instance as [SqliteTaskRepository] (co-located
/// in tasks.db). All writes are intended to be called via [unawaited] —
/// callers should not await the result.
class TurnTraceService {
  final Database _db;

  TurnTraceService(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS turns (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        task_id TEXT,
        runner_id INTEGER,
        model TEXT,
        provider TEXT,
        started_at TEXT NOT NULL,
        ended_at TEXT NOT NULL,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        is_error INTEGER NOT NULL DEFAULT 0,
        error_type TEXT,
        tool_calls TEXT
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(session_id)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_turns_task ON turns(task_id)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_turns_started ON turns(started_at)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_turns_model ON turns(model)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_turns_provider ON turns(provider)');
  }

  /// Inserts a single trace record. Intended to be called fire-and-forget.
  Future<void> insert(TurnTrace trace) async {
    final stmt = _db.prepare('''
      INSERT INTO turns (
        id, session_id, task_id, runner_id, model, provider,
        started_at, ended_at,
        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
        is_error, error_type, tool_calls
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
        trace.id,
        trace.sessionId,
        trace.taskId,
        trace.runnerId,
        trace.model,
        trace.provider,
        trace.startedAt.toIso8601String(),
        trace.endedAt.toIso8601String(),
        trace.inputTokens,
        trace.outputTokens,
        trace.cacheReadTokens,
        trace.cacheWriteTokens,
        trace.isError ? 1 : 0,
        trace.errorType,
        jsonEncode(trace.toolCalls.map((t) => t.toJson()).toList()),
      ]);
    } finally {
      stmt.close();
    }
  }

  /// Queries traces with optional filters and pagination.
  ///
  /// Returns traces and summary aggregates. The summary reflects the full
  /// filtered result set, not just the current page.
  Future<TraceQueryResult> query({
    String? taskId,
    String? sessionId,
    int? runnerId,
    String? model,
    String? provider,
    DateTime? since,
    DateTime? until,
    int limit = 50,
    int offset = 0,
  }) async {
    final effectiveLimit = limit.clamp(0, 500);
    final where = <String>[];
    final params = <Object?>[];

    if (taskId != null) {
      where.add('task_id = ?');
      params.add(taskId);
    }
    if (sessionId != null) {
      where.add('session_id = ?');
      params.add(sessionId);
    }
    if (runnerId != null) {
      where.add('runner_id = ?');
      params.add(runnerId);
    }
    if (model != null) {
      where.add('model = ?');
      params.add(model);
    }
    if (provider != null) {
      where.add('provider = ?');
      params.add(provider);
    }
    if (since != null) {
      where.add('started_at >= ?');
      params.add(since.toIso8601String());
    }
    if (until != null) {
      where.add('started_at <= ?');
      params.add(until.toIso8601String());
    }

    final whereClause = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';

    // Aggregate query (full result set, no pagination).
    final aggStmt = _db.prepare(
      'SELECT COUNT(*) as cnt, '
      'SUM(input_tokens) as total_input, SUM(output_tokens) as total_output, '
      'SUM(cache_read_tokens) as total_cache_read, SUM(cache_write_tokens) as total_cache_write, '
      'SUM(CAST(strftime(\'%s\', ended_at) AS INTEGER) - CAST(strftime(\'%s\', started_at) AS INTEGER)) * 1000 as total_duration_ms '
      'FROM turns$whereClause',
    );
    late TurnTraceSummary summary;
    try {
      final aggRows = aggStmt.select(params);
      final aggRow = aggRows.firstOrNull;
      if (aggRow == null) {
        summary = const TurnTraceSummary();
      } else {
        // tool_calls count requires a separate query since it's stored as JSON.
        final toolCountStmt = _db.prepare('SELECT tool_calls FROM turns$whereClause');
        int totalToolCalls = 0;
        try {
          final toolRows = toolCountStmt.select(params);
          for (final row in toolRows) {
            final tc = row['tool_calls'] as String?;
            if (tc != null) {
              try {
                final list = jsonDecode(tc) as List;
                totalToolCalls += list.length;
              } catch (_) {
                // malformed JSON — skip
              }
            }
          }
        } finally {
          toolCountStmt.close();
        }
        summary = TurnTraceSummary(
          totalInputTokens: (aggRow['total_input'] as num?)?.toInt() ?? 0,
          totalOutputTokens: (aggRow['total_output'] as num?)?.toInt() ?? 0,
          totalCacheReadTokens: (aggRow['total_cache_read'] as num?)?.toInt() ?? 0,
          totalCacheWriteTokens: (aggRow['total_cache_write'] as num?)?.toInt() ?? 0,
          totalDurationMs: (aggRow['total_duration_ms'] as num?)?.toInt() ?? 0,
          totalToolCalls: totalToolCalls,
          traceCount: (aggRow['cnt'] as num?)?.toInt() ?? 0,
        );
      }
    } finally {
      aggStmt.close();
    }

    // Paginated trace query.
    final dataStmt = _db.prepare(
      'SELECT * FROM turns$whereClause ORDER BY started_at DESC LIMIT ? OFFSET ?',
    );
    final traces = <TurnTrace>[];
    try {
      final rows = dataStmt.select([...params, effectiveLimit, offset]);
      for (final row in rows) {
        traces.add(_traceFromRow(row));
      }
    } finally {
      dataStmt.close();
    }

    return TraceQueryResult(traces: traces, summary: summary);
  }

  /// Returns aggregate summary for a specific task (no individual traces).
  Future<TurnTraceSummary> summaryForTask(String taskId) async {
    final result = await query(taskId: taskId, limit: 0, offset: 0);
    return result.summary;
  }

  Future<void> dispose() async {
    // No-op — db lifecycle managed by caller.
  }

  TurnTrace _traceFromRow(Row row) {
    List<ToolCallRecord> toolCalls = const [];
    final toolCallsJson = row['tool_calls'] as String?;
    if (toolCallsJson != null) {
      try {
        final list = jsonDecode(toolCallsJson) as List;
        toolCalls = list.map((e) => ToolCallRecord.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        // malformed JSON — return empty list
      }
    }
    return TurnTrace(
      id: row['id'] as String,
      sessionId: row['session_id'] as String,
      taskId: row['task_id'] as String?,
      runnerId: row['runner_id'] as int?,
      model: row['model'] as String?,
      provider: row['provider'] as String?,
      startedAt: DateTime.parse(row['started_at'] as String),
      endedAt: DateTime.parse(row['ended_at'] as String),
      inputTokens: row['input_tokens'] as int,
      outputTokens: row['output_tokens'] as int,
      cacheReadTokens: row['cache_read_tokens'] as int,
      cacheWriteTokens: row['cache_write_tokens'] as int,
      isError: (row['is_error'] as int) != 0,
      errorType: row['error_type'] as String?,
      toolCalls: toolCalls,
    );
  }
}

/// Result of a trace query: traces + summary aggregates.
class TraceQueryResult {
  final List<TurnTrace> traces;
  final TurnTraceSummary summary;

  const TraceQueryResult({required this.traces, required this.summary});

  Map<String, dynamic> toJson() => {
    'traces': traces.map((t) => t.toJson()).toList(),
    'summary': summary.toJson(),
  };
}
