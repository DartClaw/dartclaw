part of 'execution_coordinator.dart';

extension _ExecutionCoordinatorLifecycle on ExecutionCoordinator {
  /// Tears a worker down in the order the isolation boundary requires:
  /// harness termination, authority revocation, container destruction. Callers
  /// return capacity only after this completes.
  ///
  /// Returns `false` when a container revocation or destroy hook threw, so the
  /// container may still be alive: the caller must quarantine the slot rather
  /// than admit a fresh authority over a live orphan.
  ///
  /// Publishes nothing and keeps the runner's bookkeeping: the terminal event
  /// depends on the confirmation this returns, so it is published by
  /// [_completeWorkerTeardown] once the caller has quarantined capacity
  /// (ADR-058).
  Future<bool> _tearDownWorker(TurnRunner runner, ExecutionRequest request) async {
    await _stopAndDisposeHarness(runner.harness, 'worker');
    var teardownConfirmed = true;
    if (runner.executionPolicy.isContainer) {
      final context = ExecutionReleaseContext(request: request, runner: runner);
      for (final hook in _releaseHooks) {
        try {
          await hook(context);
        } catch (error, stackTrace) {
          // Destroying the container is the stronger revocation, so a failed
          // hook must not prevent it — but it is a security-relevant failure.
          teardownConfirmed = false;
          ExecutionCoordinator._log.severe('Execution release hook failed', error, stackTrace);
        }
      }
      try {
        await _destroyContainerAuthority?.call(context);
      } catch (error, stackTrace) {
        teardownConfirmed = false;
        ExecutionCoordinator._log.severe('Failed to destroy container authority', error, stackTrace);
      }
    }
    return teardownConfirmed;
  }

  /// Publishes the one terminal event for an observed teardown — `quarantined`
  /// when the caller withheld the capacity slot, `disposed` otherwise — and
  /// then drops the runner's bookkeeping, so the lease-release notification
  /// that follows carries no runner id and cannot overwrite the outcome.
  void _completeWorkerTeardown(
    TurnRunner runner,
    ExecutionRequest request,
    ExecutionLane lane, {
    required bool quarantined,
  }) {
    _emit(quarantined ? ExecutionEventKind.quarantined : ExecutionEventKind.disposed, request, lane, runner: runner);
    runner.setOutcomeObserver(null);
    _runnerIds.remove(runner);
  }

  bool _teardownNeedsQuarantine(TurnRunner runner, bool teardownConfirmed) =>
      !teardownConfirmed || !runner.harness.isRootProcessTerminationConfirmed;

  Future<void> _stopAndDisposeHarness(AgentHarness harness, String role) async {
    try {
      await harness.stop();
    } catch (error, stackTrace) {
      ExecutionCoordinator._log.warning('Failed to stop $role harness', error, stackTrace);
    }
    try {
      await harness.dispose();
    } catch (error, stackTrace) {
      ExecutionCoordinator._log.warning('Failed to dispose $role harness', error, stackTrace);
    }
  }

  Future<bool> _discardWorker(
    TurnRunner runner,
    ExecutionRequest request,
    ExecutionLane lane,
    WorkerCapacityPermit permit,
  ) async {
    final teardownConfirmed = await _tearDownWorker(runner, request);
    final quarantined = _teardownNeedsQuarantine(runner, teardownConfirmed);
    if (quarantined) permit.quarantine();
    _completeWorkerTeardown(runner, request, lane, quarantined: quarantined);
    return quarantined;
  }

  Future<void> _resetSessionContinuity(String sessionId, {bool workersOnly = false}) async {
    final ownedContainers = _cache
        .where(
          (worker) =>
              worker.lastSessionId == sessionId &&
              worker.runner.executionPolicy.isContainer &&
              worker.request.surface == ExecutionSurface.logicalAgent,
        )
        .toList();
    final relevantRunners = runners
        .where(
          (runner) => (!workersOnly || !identical(runner, _primary)) && !ownedContainers.any((w) => w.runner == runner),
        )
        .toList();
    _ActiveExecution? busyExecution;
    for (final execution in _active.values) {
      if (!workersOnly || !identical(execution.runner, _primary)) {
        busyExecution = execution;
        break;
      }
    }
    ExecutionRequest? acquiringExecution;
    for (final acquisition in _acquiring.values) {
      if (!workersOnly || acquisition.lane != ExecutionLane.primary) {
        acquiringExecution = acquisition.request;
        break;
      }
    }
    TurnRunner? busyRunner;
    for (final runner in relevantRunners) {
      if (runner.activeSessionIds.isNotEmpty) {
        busyRunner = runner;
        break;
      }
    }
    if (busyExecution != null || acquiringExecution != null || busyRunner != null) {
      final sameSession =
          busyExecution?.request.sessionId == sessionId ||
          acquiringExecution?.sessionId == sessionId ||
          (busyRunner?.activeSessionIds.contains(sessionId) ?? false);
      throw BusyTurnException(
        'Cannot reset session continuity while a relevant runner is busy',
        isSameSession: sameSession,
      );
    }
    for (final worker in ownedContainers) {
      _cache.remove(worker);
      final confirmed = await _tearDownWorker(worker.runner, worker.request);
      final quarantined = _teardownNeedsQuarantine(worker.runner, confirmed);
      if (quarantined) _workerGates[worker.request.providerId]?.quarantineAvailableSlot();
      _completeWorkerTeardown(worker.runner, worker.request, ExecutionLane.worker, quarantined: quarantined);
    }
    for (final runner in relevantRunners) {
      await runner.resetSessionContinuity(sessionId);
    }
    _forgetOutcomesForSession(sessionId);
  }

  Future<void> _disposeCoordinator() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _closing = true;
    _primaryGate.close();
    for (final gate in _workerGates.values) {
      gate.close();
    }
    if (_active.isNotEmpty || _acquiring.isNotEmpty) {
      _drained = Completer<void>();
      await _drained!.future;
    }
    for (final worker in List<_CachedWorker>.from(_cache)) {
      final confirmed = await _tearDownWorker(worker.runner, worker.request);
      // Capacity is not withheld here: every gate is already closed and the
      // coordinator is going away, so only the reported outcome still matters.
      _completeWorkerTeardown(
        worker.runner,
        worker.request,
        ExecutionLane.worker,
        quarantined: _teardownNeedsQuarantine(worker.runner, confirmed),
      );
    }
    _cache.clear();
    final primary = _primary;
    if (primary != null) {
      await _stopAndDisposeHarness(primary.harness, 'primary');
      primary.setOutcomeObserver(null);
    }
    await _events.close();
  }

  void _completeDrainIfIdle() {
    if (_active.isNotEmpty || _acquiring.isNotEmpty) return;
    _drained?.complete();
    _drained = null;
  }
}
