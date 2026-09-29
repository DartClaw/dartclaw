import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:logging/logging.dart';

import 'turn_runner.dart';
import 'runtime_tool_history.dart';
import 'turn_wait_status.dart';
import 'worker_capacity_gate.dart';
import 'runtime_context_telemetry.dart';

part 'execution_models.dart';
part 'execution_coordinator_lifecycle.dart';
part 'execution_coordinator_observability.dart';

/// Owns execution allocation for one set of fixed harness-construction inputs.
final class ExecutionCoordinator {
  new({
    required Map<String, int> providerCapacities,
    required CreateExecutionWorker createWorker,
    AdmitExecution? admitExecution,
    ReleaseExecutionAdmission? releaseAdmission,
    TurnRunner? primary,
    bool allowPrimaryBackgroundFallback = false,
    Duration outcomeTtl = const Duration(seconds: 30),
    ExecutionNow? now,
    Iterable<ExecutionReleaseHook> releaseHooks = const [],
    DestroyContainerAuthority? destroyContainerAuthority,
  }) : _createWorker = createWorker,
       _admitExecution = admitExecution,
       _releaseAdmission = releaseAdmission,
       _primary = primary,
       _releaseHooks = List.unmodifiable(releaseHooks),
       _destroyContainerAuthority = destroyContainerAuthority,
       allowsPrimaryBackgroundFallback = allowPrimaryBackgroundFallback && providerCapacities.isEmpty,
       _outcomes = _OutcomeRetention(outcomeTtl, now ?? DateTime.now),
       _workerGates = {for (final entry in providerCapacities.entries) entry.key: WorkerCapacityGate(entry.value)} {
    if ((_admitExecution == null) != (_releaseAdmission == null)) {
      throw ArgumentError('admitExecution and releaseAdmission must be configured together');
    }
    if (primary != null) {
      _observeRunner(primary, 0);
    }
  }

  static final _log = Logger('ExecutionCoordinator');

  final CreateExecutionWorker _createWorker;
  final AdmitExecution? _admitExecution;
  final ReleaseExecutionAdmission? _releaseAdmission;
  final TurnRunner? _primary;
  final List<ExecutionReleaseHook> _releaseHooks;
  final DestroyContainerAuthority? _destroyContainerAuthority;
  final bool allowsPrimaryBackgroundFallback;
  final _OutcomeRetention _outcomes;
  final WorkerCapacityGate _primaryGate = WorkerCapacityGate(1);
  final Map<String, WorkerCapacityGate> _workerGates;
  final List<_CachedWorker> _cache = [];
  final Map<TurnRunner, int> _runnerIds = Map<TurnRunner, int>.identity();
  final Map<int, _ActiveExecution> _active = {};
  final Map<int, ({ExecutionRequest request, ExecutionLane lane})> _acquiring = {};
  final StreamController<ExecutionEvent> _events = StreamController<ExecutionEvent>.broadcast();
  var _nextExecutionId = 1;
  var _nextAcquisitionId = 1;
  var _nextRunnerId = 1;
  var _closing = false;
  Completer<void>? _drained;
  Future<void>? _disposeFuture;
  RuntimeToolApprovalRequested? _toolApprovalRequested;
  RuntimeToolApprovalClosed? _toolApprovalClosed;
  RuntimeToolHistoryObserved? _toolHistoryObserved;
  RuntimeContextTelemetryObserved? _contextTelemetryObserver;

  Stream<ExecutionEvent> get events => _events.stream;
  TurnRunner? get primary => _primary;

  void setContextTelemetryObserver(RuntimeContextTelemetryObserved? observer) {
    _contextTelemetryObserver = observer;
    for (final runner in runners) {
      runner.setContextTelemetryObserver(observer);
    }
  }

  List<TurnRunner> get runners {
    final result = <TurnRunner>[];
    final primary = _primary;
    if (primary != null) result.add(primary);
    final seen = <TurnRunner>{...result};
    for (final execution in _active.values) {
      final runner = execution.runner;
      if (seen.add(runner)) result.add(runner);
    }
    for (final worker in _cache) {
      if (seen.add(worker.runner)) result.add(worker.runner);
    }
    return List.unmodifiable(result);
  }

  void setToolApprovalObservers({
    required RuntimeToolApprovalRequested? requested,
    required RuntimeToolApprovalClosed? closed,
  }) {
    _toolApprovalRequested = requested;
    _toolApprovalClosed = closed;
    for (final runner in runners) {
      runner.setToolApprovalObservers(requested: requested, closed: closed);
    }
  }

  void setToolHistoryObserver(RuntimeToolHistoryObserved? observer) {
    _toolHistoryObserved = observer;
    for (final runner in runners) {
      runner.setToolHistoryObserver(observer);
    }
  }

  void _configureHistoryObservers(TurnRunner runner) {
    runner.setToolApprovalObservers(requested: _toolApprovalRequested, closed: _toolApprovalClosed);
    runner.setToolHistoryObserver(_toolHistoryObserved);
  }

  ExecutionSnapshot get snapshot {
    return ExecutionSnapshot(
      primaryActive: _active.values.any((execution) => execution.lane == ExecutionLane.primary),
      providers: Map.unmodifiable({
        for (final entry in _workerGates.entries)
          entry.key: ProviderCapacitySnapshot(
            configured: entry.value.configuredCapacity,
            effective: entry.value.effectiveCapacity,
            active: entry.value.activeCount,
            queued: entry.value.queuedCount,
            cached: _cache.where((worker) => worker.runner.providerId == entry.key).length,
            quarantined: entry.value.quarantinedCount,
          ),
      }),
    );
  }

  Future<ExecutionLease?> acquire(ExecutionRequest request) async {
    if (_closing) {
      throw StateError('Execution coordinator is closing');
    }
    final lane = _laneFor(request);
    final routedRequest = _routeRequest(request, lane);
    if (routedRequest.providerId.trim().isEmpty) {
      throw ArgumentError.value(routedRequest.providerId, 'providerId', 'must not be blank');
    }
    final containerProfile = routedRequest.policy.containerProfile;
    if (containerProfile != null && containerProfile.trim().isEmpty) {
      throw ArgumentError.value(containerProfile, 'policy.containerProfile', 'must not be blank');
    }
    if (_admitExecution == null) {
      throw StateError('Every execution requires coordinator-owned admission');
    }
    final acquisitionId = _nextAcquisitionId++;
    _acquiring[acquisitionId] = (request: routedRequest, lane: lane);
    try {
      await _admitExecution.call(routedRequest);
      ExecutionLease? lease;
      try {
        lease = await switch (lane) {
          ExecutionLane.primary => _acquirePrimary(routedRequest),
          ExecutionLane.worker => _acquireWorker(routedRequest),
        };
      } catch (_) {
        _releaseAdmission?.call(routedRequest.sessionId);
        rethrow;
      }
      if (lease == null) _releaseAdmission?.call(routedRequest.sessionId);
      return lease;
    } finally {
      _acquiring.remove(acquisitionId);
      _completeDrainIfIdle();
    }
  }

  ExecutionLane _laneFor(ExecutionRequest request) => switch (request.surface) {
    ExecutionSurface.interactive =>
      _primary == null || request.providerId != _primary.providerId || request.policy != _primary.executionPolicy
          ? ExecutionLane.worker
          : ExecutionLane.primary,
    ExecutionSurface.temporary => ExecutionLane.worker,
    ExecutionSurface.channel => ExecutionLane.primary,
    ExecutionSurface.workflow || ExecutionSurface.logicalAgent => ExecutionLane.worker,
    ExecutionSurface.task ||
    ExecutionSurface.scheduler => allowsPrimaryBackgroundFallback ? ExecutionLane.primary : ExecutionLane.worker,
  };

  ExecutionRequest _routeRequest(ExecutionRequest request, ExecutionLane lane) {
    final primary = _primary;
    if (lane != ExecutionLane.primary || primary == null) return request;
    final backgroundFallback =
        request.surface == ExecutionSurface.task || request.surface == ExecutionSurface.scheduler;
    if (backgroundFallback && (request.providerId != primary.providerId || request.policy != primary.executionPolicy)) {
      throw StateError(
        'Single-harness fallback cannot execute ${request.providerId} ${request.policy.describe()} work on '
        '${primary.providerId} ${primary.executionPolicy.describe()}',
      );
    }
    return request._route(providerId: primary.providerId, policy: primary.executionPolicy);
  }

  Future<ExecutionLease?> _acquirePrimary(ExecutionRequest request) async {
    final primary = _primary;
    if (primary == null) {
      throw StateError('Primary execution is unavailable in this composition');
    }
    final permit = await _acquirePermit(_primaryGate, request, ExecutionLane.primary);
    if (permit == null) return null;
    if (_closing) {
      permit.release();
      throw StateError('Execution coordinator is closing');
    }
    return _register(request, ExecutionLane.primary, permit, primary);
  }

  Future<ExecutionLease?> _acquireWorker(ExecutionRequest request) async {
    final gate = _workerGates[request.providerId];
    if (gate == null) {
      throw StateError('Provider "${request.providerId}" is not configured for worker execution');
    }
    if (request.surface == ExecutionSurface.temporary) {
      final retained = _takeCached(request);
      if (retained != null) {
        final permit = retained.retainedPermit!;
        if (!_closing && retained.runner.isReusable && retained.runner.harness.state == WorkerState.idle) {
          return _register(request, ExecutionLane.worker, permit, retained.runner);
        }
        final quarantined = await _discardWorker(retained.runner, request, ExecutionLane.worker, permit);
        if (!quarantined) permit.release();
        if (_closing) throw StateError('Execution coordinator is closing');
      }
    }
    final permit = await _acquirePermit(gate, request, ExecutionLane.worker);
    if (permit == null) return null;

    try {
      var cached = _takeCached(request);
      while (cached != null && cached.runner.harness.state != WorkerState.idle) {
        if (await _discardWorker(cached.runner, request, ExecutionLane.worker, permit)) {
          throw StateError('Worker replacement blocked because root-process termination was not confirmed');
        }
        cached = _takeCached(request);
      }

      TurnRunner runner;
      if (cached != null) {
        runner = cached.runner;
      } else {
        await _scavenge(request.providerId, gate, permit);
        runner = await _createWorker(request);
        final incompatibleIdentity =
            runner.providerId != request.providerId || runner.executionPolicy != request.policy;
        if (incompatibleIdentity) {
          await _discardWorker(runner, request, ExecutionLane.worker, permit);
          throw StateError('Worker factory returned an incompatible provider or execution policy');
        }
        try {
          await runner.harness.start();
        } catch (error) {
          await _discardWorker(runner, request, ExecutionLane.worker, permit);
          throw WorkerCreationException('Failed to start ${request.providerId} worker: $error');
        }
        if (runner.harness.state != WorkerState.idle) {
          await _discardWorker(runner, request, ExecutionLane.worker, permit);
          throw StateError('Worker factory returned a harness that did not become idle after startup');
        }
        _observeRunner(runner, _nextRunnerId++);
        _configureHistoryObservers(runner);
        _emit(ExecutionEventKind.runnerCreated, request, ExecutionLane.worker, runner: runner);
      }
      if (_closing) {
        await _discardWorker(runner, request, ExecutionLane.worker, permit);
        throw StateError('Execution coordinator is closing');
      }
      return _register(request, ExecutionLane.worker, permit, runner);
    } catch (_) {
      if (gate.activeCount > 0) {
        final activeBefore = gate.activeCount;
        final queuedBefore = gate.queuedCount;
        permit.release();
        if (gate.activeCount != activeBefore || gate.queuedCount != queuedBefore) {
          _emit(ExecutionEventKind.capacityChanged, request, ExecutionLane.worker);
        }
      }
      rethrow;
    }
  }

  Future<WorkerCapacityPermit?> _acquirePermit(
    WorkerCapacityGate gate,
    ExecutionRequest request,
    ExecutionLane lane,
  ) async {
    var observedActive = gate.activeCount;
    var observedQueued = gate.queuedCount;
    void emitChange() {
      if (gate.activeCount == observedActive && gate.queuedCount == observedQueued) return;
      observedActive = gate.activeCount;
      observedQueued = gate.queuedCount;
      _emit(ExecutionEventKind.capacityChanged, request, lane);
    }

    switch (request.admission) {
      case ExecutionAdmission.failFast:
        final permit = gate.tryAcquire();
        emitChange();
        return permit;
      case ExecutionAdmission.wait:
        final pending = gate.acquire();
        emitChange();
        try {
          final permit = await pending;
          emitChange();
          return permit;
        } catch (_) {
          emitChange();
          rethrow;
        }
    }
  }

  _CachedWorker? _takeCached(ExecutionRequest request) {
    if (request.hasExecutionScopedConstructionInputs) return null;
    var index = _cache.indexWhere(
      (worker) =>
          !worker.request.hasExecutionScopedConstructionInputs &&
          worker.runner.providerId == request.providerId &&
          worker.runner.executionPolicy == request.policy &&
          worker.lastSessionId == request.sessionId &&
          worker.request.logicalAgentId == request.logicalAgentId &&
          worker.request.workspace == request.workspace &&
          worker.request.directory == request.directory &&
          (!worker.runner.executionPolicy.isContainer ||
              worker.request.surface == ExecutionSurface.logicalAgent &&
                  request.surface == ExecutionSurface.logicalAgent &&
                  worker.request.logicalAgentId == request.logicalAgentId ||
              worker.request.surface == ExecutionSurface.temporary &&
                  request.surface == ExecutionSurface.temporary &&
                  worker.lastSessionId == request.sessionId),
    );
    if (index < 0 && !request.policy.isContainer) {
      index = _cache.indexWhere(
        (worker) =>
            !worker.request.hasExecutionScopedConstructionInputs &&
            worker.runner.providerId == request.providerId &&
            worker.runner.executionPolicy == request.policy &&
            worker.request.logicalAgentId == request.logicalAgentId &&
            worker.request.workspace == request.workspace &&
            worker.request.directory == request.directory,
      );
    }
    return index < 0 ? null : _cache.removeAt(index);
  }

  Future<void> _scavenge(String providerId, WorkerCapacityGate gate, WorkerCapacityPermit permit) async {
    final allowedCached = gate.effectiveCapacity - gate.activeCount;
    bool recyclable(_CachedWorker worker) =>
        worker.runner.providerId == providerId && worker.request.surface != ExecutionSurface.temporary;
    while (_cache.where(recyclable).length > allowedCached) {
      final candidates = _cache.where(recyclable).toList()
        ..sort((left, right) => left.lastUsed.compareTo(right.lastUsed));
      final victim = candidates.first;
      _cache.remove(victim);
      if (await _discardWorker(victim.runner, victim.request, ExecutionLane.worker, permit)) {
        throw StateError('Capacity slot quarantined because root-process termination was not confirmed');
      }
    }
  }

  ExecutionLease _register(
    ExecutionRequest request,
    ExecutionLane lane,
    WorkerCapacityPermit permit,
    TurnRunner runner,
  ) {
    final executionId = _nextExecutionId++;
    final active = _ActiveExecution(request: request, lane: lane, permit: permit, runner: runner);
    _active[executionId] = active;
    final runnerId = _runnerIds.putIfAbsent(runner, () => _nextRunnerId++);
    _emit(ExecutionEventKind.acquired, request, lane, runner: runner);
    return ExecutionLease._(this, executionId, request, runner, runnerId);
  }

  Future<void> _release(int executionId) async {
    final active = _active[executionId];
    if (active == null) return;
    final runner = active.runner;
    var quarantine = false;
    var retainedPermit = false;
    if (active.lane == ExecutionLane.worker) {
      final cacheable =
          !active.request.hasExecutionScopedConstructionInputs &&
          (!runner.executionPolicy.isContainer ||
              active.request.surface == ExecutionSurface.logicalAgent ||
              active.request.surface == ExecutionSurface.temporary);
      if (cacheable && !_closing && runner.isReusable && runner.harness.state == WorkerState.idle) {
        _cache.add(
          _CachedWorker(
            runner: runner,
            lastSessionId: active.request.sessionId,
            lastUsed: DateTime.now(),
            request: active.request,
            retainedPermit: active.request.surface == ExecutionSurface.temporary ? active.permit : null,
          ),
        );
        retainedPermit = active.request.surface == ExecutionSurface.temporary;
      } else {
        final teardownConfirmed = await _tearDownWorker(runner, active.request);
        quarantine = _teardownNeedsQuarantine(runner, teardownConfirmed);
        if (quarantine) active.permit.quarantine();
        _completeWorkerTeardown(runner, active.request, active.lane, quarantined: quarantine);
      }
    }

    if (!quarantine && !retainedPermit) active.permit.release();
    _active.remove(executionId);
    try {
      _releaseAdmission?.call(active.request.sessionId);
    } finally {
      _emit(ExecutionEventKind.released, active.request, active.lane, runner: runner);
      _completeDrainIfIdle();
    }
  }

  Future<void> resetSessionContinuity(String sessionId, {bool workersOnly = false}) =>
      _resetSessionContinuity(sessionId, workersOnly: workersOnly);

  /// Releases the process-retained authority owned by one temporary session.
  Future<void> releaseTemporarySession(String sessionId) => _releaseTemporarySession(sessionId);

  Future<void> dispose() => _disposeCoordinator();
}

final class ExecutionLease {
  new _(this._coordinator, this._executionId, this.request, this.runner, this.runnerId);

  final ExecutionCoordinator _coordinator;
  final int _executionId;
  final ExecutionRequest request;
  final TurnRunner runner;
  final int runnerId;
  Future<void>? _releaseFuture;

  Future<void> release() => _releaseFuture ??= _coordinator._release(_executionId);
}

final class _ActiveExecution {
  const new({required this.request, required this.lane, required this.permit, required this.runner});

  final ExecutionRequest request;
  final ExecutionLane lane;
  final WorkerCapacityPermit permit;
  final TurnRunner runner;
}

final class _CachedWorker {
  const new({
    required this.runner,
    required this.lastSessionId,
    required this.lastUsed,
    required this.request,
    this.retainedPermit,
  });

  final TurnRunner runner;
  final String lastSessionId;
  final DateTime lastUsed;
  final ExecutionRequest request;
  final WorkerCapacityPermit? retainedPermit;
}
