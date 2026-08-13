part of 'execution_coordinator.dart';

/// Supplies wall-clock time for deterministic outcome-retention expiry.
typedef ExecutionNow = DateTime Function();

final class _OutcomeRetention {
  new(this.ttl, this.now);

  final Duration ttl;
  final ExecutionNow now;
  final Map<({String sessionId, String turnId}), ({TurnOutcome outcome, ExecutionRequest request, DateTime expiresAt})>
  entries = {};
}

extension ExecutionCoordinatorObservability on ExecutionCoordinator {
  TurnOutcome? recentOutcome(String sessionId, String turnId) {
    _evictExpiredOutcomes();
    return _outcomes.entries[(sessionId: sessionId, turnId: turnId)]?.outcome;
  }

  TurnStatusSnapshot? recentStatus(String sessionId) {
    _evictExpiredOutcomes();
    ({TurnOutcome outcome, ExecutionRequest request, DateTime expiresAt})? latest;
    for (final entry in _outcomes.entries.values) {
      if (entry.outcome.sessionId != sessionId) continue;
      if (latest == null || entry.outcome.completedAt.isAfter(latest.outcome.completedAt)) {
        latest = entry;
      }
    }
    if (latest == null) return null;
    return TurnStatusSnapshot.fromOutcome(
      sessionId: sessionId,
      outcome: latest.outcome,
      provider: latest.request.providerId,
      taskId: latest.request.taskId,
    );
  }

  void _evictExpiredOutcomes() {
    final now = _outcomes.now();
    _outcomes.entries.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
  }

  void _forgetOutcomesForSession(String sessionId) {
    _outcomes.entries.removeWhere((key, _) => key.sessionId == sessionId);
  }

  void _observeRunner(TurnRunner runner, int runnerId) {
    _runnerIds[runner] = runnerId;
    runner.setOutcomeObserver((outcome) => _recordRunnerOutcome(runner, outcome));
  }

  void _recordRunnerOutcome(TurnRunner runner, TurnOutcome outcome) {
    if (!_runnerIds.containsKey(runner)) return;
    for (final entry in _active.entries) {
      final execution = entry.value;
      if (identical(execution.runner, runner) && execution.request.sessionId == outcome.sessionId) {
        _evictExpiredOutcomes();
        _outcomes.entries[(sessionId: outcome.sessionId, turnId: outcome.turnId)] = (
          outcome: outcome,
          request: execution.request,
          expiresAt: _outcomes.now().add(_outcomes.ttl),
        );
        _emit(ExecutionEventKind.turnSettled, execution.request, execution.lane, runner: runner, outcome: outcome);
        return;
      }
    }
  }

  void _emit(
    ExecutionEventKind kind,
    ExecutionRequest request,
    ExecutionLane lane, {
    TurnRunner? runner,
    TurnOutcome? outcome,
  }) {
    if (_events.isClosed) return;
    _events.add(
      ExecutionEvent(
        kind: kind,
        request: request,
        lane: lane,
        runnerId: runner == null ? null : _runnerIds[runner],
        runner: runner,
        outcome: outcome,
      ),
    );
  }
}
