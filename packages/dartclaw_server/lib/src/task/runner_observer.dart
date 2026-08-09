import 'package:dartclaw_core/dartclaw_core.dart';

/// Runtime state of a single harness runner.
enum RunnerState { idle, busy, stopped, crashed }

/// Immutable snapshot of per-runner metrics.
class RunnerMetrics {
  final int runnerId;
  final String role;
  final String providerId;
  final RunnerState state;
  final String? currentTaskId;
  final String? currentSessionId;
  final int tokensConsumed;
  final int turnsCompleted;
  final int errorCount;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int totalTurnDurationMs;
  final int totalToolCalls;
  final int failedToolCalls;

  const RunnerMetrics({
    required this.runnerId,
    required this.role,
    required this.providerId,
    required this.state,
    this.currentTaskId,
    this.currentSessionId,
    this.tokensConsumed = 0,
    this.turnsCompleted = 0,
    this.errorCount = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.totalTurnDurationMs = 0,
    this.totalToolCalls = 0,
    this.failedToolCalls = 0,
  });

  Map<String, dynamic> toJson() => {
    'runnerId': runnerId,
    'role': role,
    'providerId': providerId,
    'state': state.name,
    'currentTaskId': currentTaskId,
    'currentSessionId': currentSessionId,
    'tokensConsumed': tokensConsumed,
    'turnsCompleted': turnsCompleted,
    'errorCount': errorCount,
    'cacheReadTokens': cacheReadTokens,
    'cacheWriteTokens': cacheWriteTokens,
    'totalTurnDurationMs': totalTurnDurationMs,
    'totalToolCalls': totalToolCalls,
    'failedToolCalls': failedToolCalls,
  };
}

/// Tracks per-runner runtime metrics for all runners in a [HarnessPool].
///
/// Uses a callback pattern: [TaskExecutor] calls [markBusy]/[markIdle] on
/// acquire/release, and [recordTurn] after each completed turn.
/// Metrics are in-memory and reset on restart.
class RunnerObserver {
  final HarnessPool _pool;
  final EventBus? _eventBus;
  final List<_MutableMetrics> _metrics;

  RunnerObserver({required HarnessPool pool, EventBus? eventBus})
    : _pool = pool,
      _eventBus = eventBus,
      _metrics = List.generate(pool.size, (i) => _MutableMetrics(runnerId: i, providerId: pool.runners[i].providerId));

  /// Mark a runner as busy with an optional task/session ID.
  void markBusy(int runnerId, {String? taskId, String? sessionId}) {
    if (runnerId < 0) return;
    _ensureCapacity(runnerId);
    final m = _metrics[runnerId];
    m.state = RunnerState.busy;
    m.currentTaskId = taskId;
    m.currentSessionId = sessionId;
    _eventBus?.fire(
      RunnerStateChangedEvent(
        runnerId: runnerId,
        state: RunnerState.busy.name,
        currentTaskId: taskId,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Mark a runner as idle, clearing task/session references.
  void markIdle(int runnerId) {
    if (runnerId < 0 || runnerId >= _metrics.length) return; // Don't grow on idle-only calls.
    final m = _metrics[runnerId];
    m.state = RunnerState.idle;
    m.currentTaskId = null;
    m.currentSessionId = null;
    _eventBus?.fire(
      RunnerStateChangedEvent(runnerId: runnerId, state: RunnerState.idle.name, timestamp: DateTime.now()),
    );
  }

  /// Record a completed turn for a runner, updating token and error counters.
  void recordTurn(
    int runnerId, {
    required int inputTokens,
    required int outputTokens,
    required bool isError,
    Duration? turnDuration,
    int cacheReadTokens = 0,
    int cacheWriteTokens = 0,
    List<ToolCallRecord> toolCalls = const [],
  }) {
    if (runnerId < 0) return;
    _ensureCapacity(runnerId);
    final m = _metrics[runnerId];
    m.tokensConsumed += inputTokens + outputTokens;
    m.turnsCompleted++;
    if (isError) m.errorCount++;
    m.cacheReadTokens += cacheReadTokens;
    m.cacheWriteTokens += cacheWriteTokens;
    m.totalTurnDurationMs += turnDuration?.inMilliseconds ?? 0;
    m.totalToolCalls += toolCalls.length;
    m.failedToolCalls += toolCalls.where((t) => !t.success).length;
  }

  /// Current metrics snapshot for all runners.
  List<RunnerMetrics> get metrics => _metrics.map((m) => m.toSnapshot()).toList();

  /// Metrics for a specific runner by index, or null if out of range.
  RunnerMetrics? metricsFor(int runnerId) {
    if (runnerId < 0 || runnerId >= _metrics.length) return null;
    return _metrics[runnerId].toSnapshot();
  }

  /// Pool-level summary.
  ({int size, int activeCount, int availableCount, int maxConcurrentWorkers}) get poolStatus => (
    size: _pool.size,
    activeCount: _pool.activeCount,
    availableCount: _pool.availableCount,
    maxConcurrentWorkers: _pool.maxConcurrentWorkers,
  );

  /// Grows [_metrics] to cover [runnerId] when the pool adds runners lazily.
  void _ensureCapacity(int runnerId) {
    while (runnerId >= _metrics.length) {
      final i = _metrics.length;
      final providerId = i < _pool.runners.length ? _pool.runners[i].providerId : 'unknown';
      _metrics.add(_MutableMetrics(runnerId: i, providerId: providerId));
    }
  }
}

class _MutableMetrics {
  final int runnerId;
  final String providerId;
  RunnerState state = RunnerState.idle;
  String? currentTaskId;
  String? currentSessionId;
  int tokensConsumed = 0;
  int turnsCompleted = 0;
  int errorCount = 0;
  int cacheReadTokens = 0;
  int cacheWriteTokens = 0;
  int totalTurnDurationMs = 0;
  int totalToolCalls = 0;
  int failedToolCalls = 0;

  _MutableMetrics({required this.runnerId, required this.providerId});

  RunnerMetrics toSnapshot() => RunnerMetrics(
    runnerId: runnerId,
    role: runnerId == 0 ? 'primary' : 'worker',
    providerId: providerId,
    state: state,
    currentTaskId: currentTaskId,
    currentSessionId: currentSessionId,
    tokensConsumed: tokensConsumed,
    turnsCompleted: turnsCompleted,
    errorCount: errorCount,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
    totalTurnDurationMs: totalTurnDurationMs,
    totalToolCalls: totalToolCalls,
    failedToolCalls: failedToolCalls,
  );
}
