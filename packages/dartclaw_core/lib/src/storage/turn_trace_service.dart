import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show TurnTrace, TurnTraceSummary, ToolCallRecord;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show DatabaseBackend;

import 'file_execution_store.dart';

/// Persistence for turn traces.
class TurnTraceService {
  final DatabaseBackend? _backend;
  final FileExecutionStore? _fileStore;

  /// Creates the service against a prepared task [backend].
  new(this._backend) : _fileStore = null;

  /// Creates the service against a standalone execution checkpoint.
  new file(FileExecutionStore store) : _backend = null, _fileStore = store;

  /// Inserts a single trace record.
  Future<void> insert(TurnTrace trace) async {
    final fileStore = _fileStore;
    if (fileStore != null) {
      await fileStore.update((state) {
        final traces = state['traces'] as Map<String, dynamic>;
        if (traces.containsKey(trace.id)) throw StateError('TurnTrace already exists: ${trace.id}');
        traces[trace.id] = trace.toJson();
      });
      return;
    }
    final stmt = await _backend!.prepare('''
      INSERT INTO turns (
        id, session_id, task_id, runner_id, model, provider,
        started_at, ended_at,
        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
        is_error, error_type, tool_calls
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      await stmt.execute([
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
        jsonEncode({
          'records': trace.toolCalls.map((t) => t.toJson()).toList(),
          'count': trace.toolCallCount,
          'failedCount': trace.failedToolCallCount,
          'truncated': trace.toolCallsTruncated,
        }),
      ]);
    } finally {
      await stmt.close();
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
    final fileStore = _fileStore;
    if (fileStore != null) {
      return fileStore.read((state) {
        final filtered = (state['traces'] as Map<String, dynamic>).values
            .map((row) => TurnTrace.fromJson(Map<String, dynamic>.from(row as Map)))
            .where(
              (trace) =>
                  (taskId == null || trace.taskId == taskId) &&
                  (sessionId == null || trace.sessionId == sessionId) &&
                  (runnerId == null || trace.runnerId == runnerId) &&
                  (model == null || trace.model == model) &&
                  (provider == null || trace.provider == provider) &&
                  (since == null || !trace.startedAt.isBefore(since)) &&
                  (until == null || !trace.startedAt.isAfter(until)),
            )
            .toList();
        filtered.sort((a, b) => b.startedAt.compareTo(a.startedAt));
        final summary = TurnTraceSummary(
          totalInputTokens: filtered.fold(0, (total, trace) => total + trace.inputTokens),
          totalOutputTokens: filtered.fold(0, (total, trace) => total + trace.outputTokens),
          totalCacheReadTokens: filtered.fold(0, (total, trace) => total + trace.cacheReadTokens),
          totalCacheWriteTokens: filtered.fold(0, (total, trace) => total + trace.cacheWriteTokens),
          totalDurationMs: filtered.fold(0, (total, trace) => total + trace.durationMs),
          totalToolCalls: filtered.fold(0, (total, trace) => total + trace.toolCallCount),
          traceCount: filtered.length,
        );
        return TraceQueryResult(traces: filtered.skip(offset).take(limit.clamp(0, 500)).toList(), summary: summary);
      });
    }
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

    // The summary covers the full filtered set, not the page. It is summed here because tool calls are stored as
    // JSON and timestamps as ISO text, and engine SUM types differ (PostgreSQL widens BIGINT sums to NUMERIC).
    final summaryStmt = await _backend!.prepare(
      'SELECT input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, started_at, ended_at, tool_calls '
      'FROM turns$whereClause',
    );
    final List<Map<String, Object?>> summaryRows;
    try {
      summaryRows = await summaryStmt.query(params);
    } finally {
      await summaryStmt.close();
    }
    int sum(String column) => summaryRows.fold(0, (total, row) => total + (row[column] as int? ?? 0));
    final summary = TurnTraceSummary(
      totalInputTokens: sum('input_tokens'),
      totalOutputTokens: sum('output_tokens'),
      totalCacheReadTokens: sum('cache_read_tokens'),
      totalCacheWriteTokens: sum('cache_write_tokens'),
      totalDurationMs: summaryRows.fold(
        0,
        (total, row) =>
            total +
            DateTime.parse(row['ended_at'] as String)
                .difference(DateTime.parse(row['started_at'] as String))
                .inMilliseconds,
      ),
      totalToolCalls: summaryRows.fold(0, (total, row) {
        final toolCalls = row['tool_calls'] as String?;
        return total + (toolCalls == null ? 0 : _decodeToolCalls(toolCalls).count);
      }),
      traceCount: summaryRows.length,
    );

    // Paginated trace query.
    final dataStmt = await _backend.prepare(
      'SELECT * FROM turns$whereClause ORDER BY started_at DESC LIMIT ? OFFSET ?',
    );
    final traces = <TurnTrace>[];
    try {
      final rows = await dataStmt.query([...params, effectiveLimit, offset]);
      for (final row in rows) {
        traces.add(_traceFromRow(row));
      }
    } finally {
      await dataStmt.close();
    }

    return TraceQueryResult(traces: traces, summary: summary);
  }

  /// Returns aggregate summary for a specific task (no individual traces).
  Future<TurnTraceSummary> summaryForTask(String taskId) async {
    final result = await query(taskId: taskId, limit: 0, offset: 0);
    return result.summary;
  }

  /// Returns a single trace by ID, or null when it does not exist.
  Future<TurnTrace?> getById(String id) async {
    final fileStore = _fileStore;
    if (fileStore != null) {
      return fileStore.read((state) {
        final row = (state['traces'] as Map<String, dynamic>)[id];
        return row == null ? null : TurnTrace.fromJson(Map<String, dynamic>.from(row as Map));
      });
    }
    final stmt = await _backend!.prepare('SELECT * FROM turns WHERE id = ? LIMIT 1');
    try {
      final rows = await stmt.query([id]);
      final row = rows.firstOrNull;
      if (row == null) {
        return null;
      }
      return _traceFromRow(row);
    } finally {
      await stmt.close();
    }
  }

  /// Releases service-owned resources; the database lifecycle is the caller's.
  Future<void> dispose() async {
    // No-op — db lifecycle managed by caller.
  }

  TurnTrace _traceFromRow(Map<String, Object?> row) {
    final storedToolCalls = _decodeToolCalls(row['tool_calls'] as String?);
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
      toolCalls: storedToolCalls.records,
      toolCallCount: storedToolCalls.count,
      failedToolCallCount: storedToolCalls.failedCount,
    );
  }
}

({List<ToolCallRecord> records, int count, int failedCount}) _decodeToolCalls(String? encoded) {
  if (encoded == null) return (records: const [], count: 0, failedCount: 0);
  try {
    final decoded = jsonDecode(encoded);
    final rawRecords = decoded is List ? decoded : (decoded as Map<String, dynamic>)['records'] as List? ?? const [];
    final records = rawRecords.map((value) => ToolCallRecord.fromJson(value as Map<String, dynamic>)).toList();
    if (decoded is! Map<String, dynamic>) {
      return (records: records, count: records.length, failedCount: records.where((call) => !call.success).length);
    }
    return (
      records: records,
      count: (decoded['count'] as num?)?.toInt() ?? records.length,
      failedCount: (decoded['failedCount'] as num?)?.toInt() ?? records.where((call) => !call.success).length,
    );
  } catch (_) {
    return (records: const [], count: 0, failedCount: 0);
  }
}

/// Result of a trace query: traces + summary aggregates.
class TraceQueryResult {
  /// Individual turn traces matching the query.
  final List<TurnTrace> traces;

  /// Aggregate summary across [traces].
  final TurnTraceSummary summary;

  /// Creates a query result from [traces] and their [summary].
  const new({required this.traces, required this.summary});

  /// Serializes this result to a JSON-ready map.
  Map<String, dynamic> toJson() => {'traces': traces.map((t) => t.toJson()).toList(), 'summary': summary.toJson()};
}
