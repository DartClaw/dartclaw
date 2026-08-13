import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:logging/logging.dart';

import 'turn_runner.dart';
import 'turn_wait_status.dart';
import 'worker_capacity_gate.dart';

part 'execution_models.dart';
part 'execution_coordinator_lifecycle.dart';
part 'execution_coordinator_observability.dart';

/// Owns execution allocation for one set of fixed harness-construction inputs.
final class ExecutionCoordinator {
  ExecutionCoordinator({
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

  Stream<ExecutionEvent> get events => _events.stream;
  TurnRunner? get primary => _primary;

  List<TurnRunner> get runners {
    final result = <TurnRunner>[];
    final primary = _primary;
    if (primary != null) result.add(primary);
    final seen = <TurnRunner>{...result};
    for (final execution in _active.values) {
      final runner = execution.runner;
      if (runner != null && seen.add(runner)) result.add(runner);
    }
    for (final worker in _cache) {
      if (seen.add(worker.runner)) result.add(worker.runner);
    }
    return List.unmodifiable(result);
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
    final lane = _laneFor(request.surface);
    final routedRequest = _routeRequest(request, lane);
    if (routedRequest.providerId.trim().isEmpty) {
      throw ArgumentError.value(routedRequest.providerId, 'providerId', 'must not be blank');
    }
    final containerProfile = routedRequest.policy.containerProfile;
    if (containerProfile != null && containerProfile.trim().isEmpty) {
      throw ArgumentError.value(containerProfile, 'policy.containerProfile', 'must not be blank');
    }
    if (lane != ExecutionLane.capacityOnly && _admitExecution == null) {
      throw StateError('Primary and worker execution require coordinator-owned admission');
    }
    final acquisitionId = _nextAcquisitionId++;
    _acquiring[acquisitionId] = (request: routedRequest, lane: lane);
    try {
      await _admitExecution?.call(routedRequest);
      ExecutionLease? lease;
      try {
        lease = await switch (lane) {
          ExecutionLane.primary => _acquirePrimary(routedRequest),
          ExecutionLane.worker || ExecutionLane.capacityOnly => _acquireWorker(routedRequest, lane),
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

  ExecutionLane _laneFor(ExecutionSurface surface) => switch (surface) {
    ExecutionSurface.interactive || ExecutionSurface.channel => ExecutionLane.primary,
    ExecutionSurface.workflow => ExecutionLane.capacityOnly,
    ExecutionSurface.logicalAgent || ExecutionSurface.advisor => ExecutionLane.worker,
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

  Future<ExecutionLease?> _acquireWorker(ExecutionRequest request, ExecutionLane lane) async {
    final gate = _workerGates[request.providerId];
    if (gate == null) {
      throw StateError('Provider "${request.providerId}" is not configured for worker execution');
    }
    final permit = await _acquirePermit(gate, request, lane);
    if (permit == null) return null;

    try {
      if (lane == ExecutionLane.capacityOnly) {
        if (_closing) throw StateError('Execution coordinator is closing');
        return _register(request, lane, permit, null);
      }

      var cached = _takeCached(request);
      while (cached != null && cached.runner.harness.state != WorkerState.idle) {
        if (await _discardWorker(cached.runner, request, lane, permit)) {
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
          await _discardWorker(runner, request, lane, permit);
          throw StateError('Worker factory returned an incompatible provider or execution policy');
        }
        try {
          await runner.harness.start();
        } catch (error) {
          await _discardWorker(runner, request, lane, permit);
          throw WorkerCreationException('Failed to start ${request.providerId} worker: $error');
        }
        if (runner.harness.state != WorkerState.idle) {
          await _discardWorker(runner, request, lane, permit);
          throw StateError('Worker factory returned a harness that did not become idle after startup');
        }
        _observeRunner(runner, _nextRunnerId++);
        _emit(ExecutionEventKind.runnerCreated, request, lane, runner: runner);
      }
      if (_closing) {
        await _discardWorker(runner, request, lane, permit);
        throw StateError('Execution coordinator is closing');
      }
      return _register(request, lane, permit, runner);
    } catch (_) {
      if (gate.activeCount > 0) {
        final activeBefore = gate.activeCount;
        final queuedBefore = gate.queuedCount;
        permit.release();
        if (gate.activeCount != activeBefore || gate.queuedCount != queuedBefore) {
          _emit(ExecutionEventKind.capacityChanged, request, lane);
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
    var index = _cache.indexWhere(
      (worker) =>
          worker.runner.providerId == request.providerId &&
          worker.runner.executionPolicy == request.policy &&
          worker.lastSessionId == request.sessionId &&
          (!worker.runner.executionPolicy.isContainer ||
              worker.request.surface == ExecutionSurface.logicalAgent &&
                  request.surface == ExecutionSurface.logicalAgent &&
                  worker.request.logicalAgentId == request.logicalAgentId),
    );
    if (index < 0 && !request.policy.isContainer) {
      index = _cache.indexWhere(
        (worker) => worker.runner.providerId == request.providerId && worker.runner.executionPolicy == request.policy,
      );
    }
    return index < 0 ? null : _cache.removeAt(index);
  }

  Future<void> _scavenge(String providerId, WorkerCapacityGate gate, WorkerCapacityPermit permit) async {
    final allowedCached = gate.effectiveCapacity - gate.activeCount;
    while (_cache.where((worker) => worker.runner.providerId == providerId).length > allowedCached) {
      final candidates = _cache.where((worker) => worker.runner.providerId == providerId).toList()
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
    TurnRunner? runner,
  ) {
    final executionId = _nextExecutionId++;
    final active = _ActiveExecution(request: request, lane: lane, permit: permit, runner: runner);
    _active[executionId] = active;
    final runnerId = runner == null ? null : _runnerIds.putIfAbsent(runner, () => _nextRunnerId++);
    _emit(ExecutionEventKind.acquired, request, lane, runner: runner);
    return ExecutionLease._(this, executionId, request, lane, runner, runnerId);
  }

  Future<void> _release(int executionId, {bool forceQuarantine = false}) async {
    final active = _active[executionId];
    if (active == null) return;
    final runner = active.runner;
    var quarantine = false;
    if (runner != null && active.lane == ExecutionLane.worker) {
      final cacheable = !runner.executionPolicy.isContainer || active.request.surface == ExecutionSurface.logicalAgent;
      if (cacheable && !_closing && runner.isReusable && runner.harness.state == WorkerState.idle) {
        _cache.add(
          _CachedWorker(
            runner: runner,
            lastSessionId: active.request.sessionId,
            lastUsed: DateTime.now(),
            request: active.request,
          ),
        );
      } else {
        final teardownConfirmed = await _disposeWorker(runner, active.request);
        quarantine = !teardownConfirmed || !runner.harness.isRootProcessTerminationConfirmed;
      }
    }

    if (quarantine || forceQuarantine) {
      active.permit.quarantine();
      _emit(ExecutionEventKind.quarantined, active.request, active.lane, runner: runner);
    } else {
      active.permit.release();
    }
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

  Future<void> dispose() => _disposeCoordinator();
}

final class ExecutionLease {
  ExecutionLease._(this._coordinator, this._executionId, this.request, this._lane, this.runner, this.runnerId);

  final ExecutionCoordinator _coordinator;
  final int _executionId;
  final ExecutionRequest request;
  final ExecutionLane _lane;
  final TurnRunner? runner;
  final int? runnerId;
  Future<void>? _releaseFuture;

  Future<void> release() => _releaseFuture ??= _coordinator._release(_executionId);

  /// Permanently removes a capacity-only slot when caller-managed teardown cannot be confirmed.
  Future<void> quarantine() {
    if (_lane != ExecutionLane.capacityOnly) {
      throw StateError('Only capacity-only leases may be quarantined by their caller');
    }
    return _releaseFuture ??= _coordinator._release(_executionId, forceQuarantine: true);
  }
}

final class _ActiveExecution {
  const _ActiveExecution({required this.request, required this.lane, required this.permit, required this.runner});

  final ExecutionRequest request;
  final ExecutionLane lane;
  final WorkerCapacityPermit permit;
  final TurnRunner? runner;
}

final class _CachedWorker {
  const _CachedWorker({
    required this.runner,
    required this.lastSessionId,
    required this.lastUsed,
    required this.request,
  });

  final TurnRunner runner;
  final String lastSessionId;
  final DateTime lastUsed;
  final ExecutionRequest request;
}
