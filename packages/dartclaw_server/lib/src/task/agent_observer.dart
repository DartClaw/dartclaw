import 'package:dartclaw_core/dartclaw_core.dart';

import '../harness_pool.dart';

/// Runtime state of a single agent runner.
enum AgentState { idle, busy, stopped, crashed }

/// Immutable snapshot of per-runner metrics.
class AgentMetrics {
  final int runnerId;
  final String role;
  final String providerId;
  final AgentState state;
  final String? currentTaskId;
  final String? currentSessionId;
  final int tokensConsumed;
  final int turnsCompleted;
  final int errorCount;

  const AgentMetrics({
    required this.runnerId,
    required this.role,
    required this.providerId,
    required this.state,
    this.currentTaskId,
    this.currentSessionId,
    this.tokensConsumed = 0,
    this.turnsCompleted = 0,
    this.errorCount = 0,
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
  };
}

/// Tracks per-runner runtime metrics for all runners in a [HarnessPool].
///
/// Uses a callback pattern: [TaskExecutor] calls [markBusy]/[markIdle] on
/// acquire/release, and [recordTurn] after each completed turn.
/// Metrics are in-memory and reset on restart.
class AgentObserver {
  final HarnessPool _pool;
  final EventBus? _eventBus;
  final List<_MutableMetrics> _metrics;

  AgentObserver({required HarnessPool pool, EventBus? eventBus})
    : _pool = pool,
      _eventBus = eventBus,
      _metrics = List.generate(pool.size, (i) => _MutableMetrics(runnerId: i, providerId: pool.runners[i].providerId));

  /// Mark a runner as busy with an optional task/session ID.
  void markBusy(int runnerId, {String? taskId, String? sessionId}) {
    if (runnerId < 0 || runnerId >= _metrics.length) return;
    final m = _metrics[runnerId];
    m.state = AgentState.busy;
    m.currentTaskId = taskId;
    m.currentSessionId = sessionId;
    _eventBus?.fire(
      AgentStateChangedEvent(
        runnerId: runnerId,
        state: AgentState.busy.name,
        currentTaskId: taskId,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Mark a runner as idle, clearing task/session references.
  void markIdle(int runnerId) {
    if (runnerId < 0 || runnerId >= _metrics.length) return;
    final m = _metrics[runnerId];
    m.state = AgentState.idle;
    m.currentTaskId = null;
    m.currentSessionId = null;
    _eventBus?.fire(AgentStateChangedEvent(runnerId: runnerId, state: AgentState.idle.name, timestamp: DateTime.now()));
  }

  /// Record a completed turn for a runner, updating token and error counters.
  void recordTurn(int runnerId, {required int inputTokens, required int outputTokens, required bool isError}) {
    if (runnerId < 0 || runnerId >= _metrics.length) return;
    final m = _metrics[runnerId];
    m.tokensConsumed += inputTokens + outputTokens;
    m.turnsCompleted++;
    if (isError) m.errorCount++;
  }

  /// Current metrics snapshot for all runners.
  List<AgentMetrics> get metrics => _metrics.map((m) => m.toSnapshot()).toList();

  /// Metrics for a specific runner by index, or null if out of range.
  AgentMetrics? metricsFor(int runnerId) {
    if (runnerId < 0 || runnerId >= _metrics.length) return null;
    return _metrics[runnerId].toSnapshot();
  }

  /// Pool-level summary.
  ({int size, int activeCount, int availableCount, int maxConcurrentTasks}) get poolStatus => (
    size: _pool.size,
    activeCount: _pool.activeCount,
    availableCount: _pool.availableCount,
    maxConcurrentTasks: _pool.maxConcurrentTasks,
  );

  void dispose() {
    // No subscriptions to cancel in callback-based approach.
  }
}

class _MutableMetrics {
  final int runnerId;
  final String providerId;
  AgentState state = AgentState.idle;
  String? currentTaskId;
  String? currentSessionId;
  int tokensConsumed = 0;
  int turnsCompleted = 0;
  int errorCount = 0;

  _MutableMetrics({required this.runnerId, required this.providerId});

  AgentMetrics toSnapshot() => AgentMetrics(
    runnerId: runnerId,
    role: runnerId == 0 ? 'primary' : 'task',
    providerId: providerId,
    state: state,
    currentTaskId: currentTaskId,
    currentSessionId: currentSessionId,
    tokensConsumed: tokensConsumed,
    turnsCompleted: turnsCompleted,
    errorCount: errorCount,
  );
}
