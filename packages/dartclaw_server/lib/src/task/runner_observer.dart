import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

import '../execution_coordinator.dart';

enum RunnerState { idle, busy, stopped, crashed }

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

final class ExecutionCapacityMetrics {
  const ExecutionCapacityMetrics({
    required this.runnerCount,
    required this.configured,
    required this.effective,
    required this.active,
    required this.available,
    required this.queued,
    required this.cached,
    required this.quarantined,
    required this.primaryActive,
  });

  final int runnerCount;
  final int configured;
  final int effective;
  final int active;
  final int available;
  final int queued;
  final int cached;
  final int quarantined;
  final bool primaryActive;

  Map<String, dynamic> toJson() => {
    'runnerCount': runnerCount,
    'configured': configured,
    'effective': effective,
    'active': active,
    'available': available,
    'queued': queued,
    'cached': cached,
    'quarantined': quarantined,
    'primaryActive': primaryActive,
  };
}

/// Derives runner lifecycle from execution leases and retains aggregate turn metrics.
class RunnerObserver {
  RunnerObserver({required ExecutionCoordinator executions, EventBus? eventBus})
    : _executions = executions,
      _eventBus = eventBus {
    for (final runner in executions.runners) {
      final runnerId = identical(runner, executions.primary) ? 0 : null;
      if (runnerId != null) {
        _ensureRunner(runnerId, runner.providerId, role: 'primary');
      }
    }
    _subscription = executions.events.listen(_onExecutionEvent);
  }

  final ExecutionCoordinator _executions;
  final EventBus? _eventBus;
  final Map<int, _MutableMetrics> _metrics = {};
  final StreamController<ExecutionCapacityMetrics> _capacityChanges =
      StreamController<ExecutionCapacityMetrics>.broadcast();
  late final StreamSubscription<ExecutionEvent> _subscription;

  void _onExecutionEvent(ExecutionEvent event) {
    final runnerId = event.runnerId;
    final runner = event.runner;
    if (runnerId != null && runner != null) {
      final metrics = _ensureRunner(
        runnerId,
        event.request.providerId,
        role: event.lane == ExecutionLane.primary ? 'primary' : 'worker',
      );
      switch (event.kind) {
        case ExecutionEventKind.capacityChanged:
          break;
        case ExecutionEventKind.acquired:
          _markBusy(metrics, taskId: event.request.taskId, sessionId: event.request.sessionId);
        case ExecutionEventKind.disposed:
          _markTerminal(metrics, runner.harness.state);
          _metrics.remove(runnerId);
        case ExecutionEventKind.quarantined:
          _setState(metrics, RunnerState.crashed);
        case ExecutionEventKind.released:
          if (runner.harness.state == WorkerState.idle) {
            _markIdle(metrics);
          } else {
            _markTerminal(metrics, runner.harness.state);
          }
        case ExecutionEventKind.runnerCreated:
          break;
        case ExecutionEventKind.turnSettled:
          final outcome = event.outcome;
          if (outcome != null) _recordTurn(metrics, outcome);
      }
    }
    if (event.kind != ExecutionEventKind.turnSettled && !_capacityChanges.isClosed) {
      _capacityChanges.add(capacityStatus);
    }
  }

  void _recordTurn(_MutableMetrics metrics, TurnOutcome outcome) {
    metrics.tokensConsumed += outcome.inputTokens + outcome.outputTokens;
    metrics.turnsCompleted++;
    if (outcome.status != TurnStatus.completed) metrics.errorCount++;
    metrics.cacheReadTokens += outcome.cacheReadTokens;
    metrics.cacheWriteTokens += outcome.cacheWriteTokens;
    metrics.totalTurnDurationMs += outcome.turnDuration.inMilliseconds;
    metrics.totalToolCalls += outcome.toolCallCount;
    metrics.failedToolCalls += outcome.failedToolCallCount;
  }

  List<RunnerMetrics> get metrics {
    final ids = _metrics.keys.toList()..sort();
    return ids.map((id) => _metrics[id]!.toSnapshot()).toList(growable: false);
  }

  RunnerMetrics? metricsFor(int runnerId) => _metrics[runnerId]?.toSnapshot();

  ExecutionCapacityMetrics get capacityStatus {
    final snapshot = _executions.snapshot;
    return ExecutionCapacityMetrics(
      runnerCount: _metrics.length,
      configured: snapshot.configuredWorkers,
      effective: snapshot.effectiveWorkers,
      active: snapshot.activeWorkers,
      available: snapshot.availableWorkers,
      queued: snapshot.queuedWorkers,
      cached: snapshot.cachedWorkers,
      quarantined: snapshot.quarantinedWorkers,
      primaryActive: snapshot.primaryActive,
    );
  }

  Stream<ExecutionCapacityMetrics> get capacityChanges => _capacityChanges.stream;

  Future<void> dispose() async {
    await _subscription.cancel();
    await _capacityChanges.close();
  }

  _MutableMetrics _ensureRunner(int runnerId, String providerId, {required String role}) {
    return _metrics.putIfAbsent(
      runnerId,
      () => _MutableMetrics(runnerId: runnerId, providerId: providerId, role: role),
    );
  }

  void _markBusy(_MutableMetrics metrics, {String? taskId, String? sessionId}) {
    metrics.state = RunnerState.busy;
    metrics.currentTaskId = taskId;
    metrics.currentSessionId = sessionId;
    _fireState(metrics);
  }

  void _markIdle(_MutableMetrics metrics) {
    metrics.state = RunnerState.idle;
    metrics.currentTaskId = null;
    metrics.currentSessionId = null;
    _fireState(metrics);
  }

  void _markTerminal(_MutableMetrics metrics, WorkerState state) {
    _setState(metrics, state == WorkerState.crashed ? RunnerState.crashed : RunnerState.stopped);
  }

  void _setState(_MutableMetrics metrics, RunnerState state) {
    metrics.state = state;
    metrics.currentTaskId = null;
    metrics.currentSessionId = null;
    _fireState(metrics);
  }

  void _fireState(_MutableMetrics metrics) {
    _eventBus?.fire(
      RunnerStateChangedEvent(
        runnerId: metrics.runnerId,
        state: metrics.state.name,
        currentTaskId: metrics.currentTaskId,
        timestamp: DateTime.now(),
      ),
    );
  }
}

class _MutableMetrics {
  final int runnerId;
  final String role;
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

  _MutableMetrics({required this.runnerId, required this.role, required this.providerId});

  RunnerMetrics toSnapshot() => RunnerMetrics(
    runnerId: runnerId,
    role: role,
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
