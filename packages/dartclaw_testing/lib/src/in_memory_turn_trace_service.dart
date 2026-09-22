import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// In-memory turn-trace service for tests that do not exercise SQL.
final class InMemoryTurnTraceService extends TurnTraceService {
  new() : super(_UnusedDatabaseBackend());

  final Map<String, TurnTrace> _traces = {};
  var _closed = false;

  @override
  Future<void> insert(TurnTrace trace) async {
    _ensureOpen();
    _traces[trace.id] = trace;
  }

  @override
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
    _ensureOpen();
    final matching =
        _traces.values
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
            .toList()
          ..sort((left, right) => right.startedAt.compareTo(left.startedAt));

    final summary = TurnTraceSummary(
      totalInputTokens: matching.fold(0, (total, trace) => total + trace.inputTokens),
      totalOutputTokens: matching.fold(0, (total, trace) => total + trace.outputTokens),
      totalCacheReadTokens: matching.fold(0, (total, trace) => total + trace.cacheReadTokens),
      totalCacheWriteTokens: matching.fold(0, (total, trace) => total + trace.cacheWriteTokens),
      totalDurationMs: matching.fold(0, (total, trace) => total + trace.durationMs),
      totalToolCalls: matching.fold(0, (total, trace) => total + trace.toolCallCount),
      traceCount: matching.length,
    );
    final effectiveLimit = limit.clamp(0, 500);
    return TraceQueryResult(traces: matching.skip(offset).take(effectiveLimit).toList(), summary: summary);
  }

  @override
  Future<TurnTraceSummary> summaryForTask(String taskId) async => (await query(taskId: taskId, limit: 0)).summary;

  @override
  Future<TurnTrace?> getById(String id) async {
    _ensureOpen();
    return _traces[id];
  }

  @override
  Future<void> dispose() async => _closed = true;

  void _ensureOpen() {
    if (_closed) throw StateError('Turn trace service is closed');
  }
}

final class _UnusedDatabaseBackend implements DatabaseBackend {
  @override
  Future<void> close() async {}

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) =>
      throw UnsupportedError('The in-memory turn trace service does not use SQL');

  @override
  Future<DatabaseStatement> prepare(String sql) =>
      throw UnsupportedError('The in-memory turn trace service does not use SQL');

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      throw UnsupportedError('The in-memory turn trace service does not use SQL');

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) => body(this);
}
