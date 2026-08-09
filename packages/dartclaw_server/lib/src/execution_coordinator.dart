import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:logging/logging.dart';

import 'turn_runner.dart';
import 'turn_wait_status.dart';
import 'worker_capacity_gate.dart';

part 'execution_models.dart';
part 'execution_coordinator_observability.dart';
part 'execution_coordinator_validation.dart';

/// Owns primary and worker execution allocation after global governance admission.
final class ExecutionCoordinator {
  ExecutionCoordinator({
    required Map<String, int> providerCapacities,
    required CreateExecutionWorker createWorker,
    ResolveExecutionFingerprint? resolveFingerprint,
    AdmitExecution? admitExecution,
    ReleaseExecutionAdmission? releaseAdmission,
    TurnRunner? primary,
    bool allowPrimaryBackgroundFallback = false,
    Duration outcomeTtl = const Duration(seconds: 30),
    ExecutionNow? now,
  }) : _createWorker = createWorker,
       _resolveFingerprint = resolveFingerprint ?? _defaultFingerprint,
       _admitExecution = admitExecution,
       _releaseAdmission = releaseAdmission,
       _primary = primary,
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
  final ResolveExecutionFingerprint _resolveFingerprint;
  final AdmitExecution? _admitExecution;
  final ReleaseExecutionAdmission? _releaseAdmission;
  final TurnRunner? _primary;
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
  bool get ownsAdmission => _admitExecution != null;
  ExecutionFingerprint fingerprintFor(String providerId, String profileId) =>
      _resolveFingerprint(providerId, profileId);

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
            cached: _cache.where((worker) => worker.fingerprint.providerId == entry.key).length,
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
    _validateRequest(routedRequest, lane);
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
    ExecutionSurface.scheduler ||
    ExecutionSurface.system => allowsPrimaryBackgroundFallback ? ExecutionLane.primary : ExecutionLane.worker,
  };

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
        await _scavenge(request.providerId, gate, permit);
        if (_closing) throw StateError('Execution coordinator is closing');
        return _register(request, lane, permit, null);
      }

      var cached = _takeCached(request);
      while (cached != null && cached.runner.harness.state != WorkerState.idle) {
        await _disposeWorker(cached.runner, request, executionId: 0);
        if (!cached.runner.harness.isRootProcessTerminationConfirmed) {
          permit.quarantine();
          _emit(ExecutionEventKind.quarantined, request, lane, 0, runner: cached.runner);
          throw StateError('Worker replacement blocked because root-process termination was not confirmed');
        }
        cached = _takeCached(request);
      }

      TurnRunner runner;
      if (cached != null) {
        runner = cached.runner;
      } else {
        await _scavenge(request.providerId, gate, permit);
        try {
          runner = await _createWorker(request);
        } on WorkerCreationException catch (error) {
          if (error.quarantineSlot) {
            permit.quarantine();
            _emit(ExecutionEventKind.quarantined, request, lane, 0);
          }
          rethrow;
        }
        final incompatibleIdentity = runner.providerId != request.providerId || runner.profileId != request.profileId;
        final unhealthy = runner.harness.state != WorkerState.idle;
        if (incompatibleIdentity || unhealthy) {
          await _disposeWorker(runner, request, executionId: 0);
          if (!runner.harness.isRootProcessTerminationConfirmed) {
            permit.quarantine();
            _emit(ExecutionEventKind.quarantined, request, lane, 0, runner: runner);
          }
          throw StateError(
            incompatibleIdentity
                ? 'Worker factory returned an incompatible provider or security profile'
                : 'Worker factory returned a non-idle harness',
          );
        }
        _observeRunner(runner, _nextRunnerId++);
        _emit(ExecutionEventKind.runnerCreated, request, lane, 0, runner: runner);
      }
      if (_closing) {
        await _disposeWorker(runner, request, executionId: 0);
        if (!runner.harness.isRootProcessTerminationConfirmed) {
          permit.quarantine();
          _emit(ExecutionEventKind.quarantined, request, lane, 0, runner: runner);
        }
        throw StateError('Execution coordinator is closing');
      }
      return _register(request, lane, permit, runner);
    } catch (_) {
      if (gate.activeCount > 0) {
        final activeBefore = gate.activeCount;
        final queuedBefore = gate.queuedCount;
        permit.release();
        if (gate.activeCount != activeBefore || gate.queuedCount != queuedBefore) {
          _emit(ExecutionEventKind.capacityChanged, request, lane, 0);
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
      _emit(ExecutionEventKind.capacityChanged, request, lane, 0);
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
      (worker) => worker.fingerprint == request.fingerprint && worker.lastSessionId == request.sessionId,
    );
    if (index < 0) {
      index = _cache.indexWhere((worker) => worker.fingerprint == request.fingerprint);
    }
    return index < 0 ? null : _cache.removeAt(index);
  }

  Future<void> _scavenge(String providerId, WorkerCapacityGate gate, WorkerCapacityPermit permit) async {
    final allowedCached = gate.effectiveCapacity - gate.activeCount;
    while (_cache.where((worker) => worker.fingerprint.providerId == providerId).length > allowedCached) {
      final candidates = _cache.where((worker) => worker.fingerprint.providerId == providerId).toList()
        ..sort((left, right) => left.lastUsed.compareTo(right.lastUsed));
      final victim = candidates.first;
      _cache.remove(victim);
      await _disposeWorker(victim.runner, victim.request, executionId: 0);
      if (!victim.runner.harness.isRootProcessTerminationConfirmed) {
        permit.quarantine();
        _emit(ExecutionEventKind.quarantined, victim.request, ExecutionLane.worker, 0, runner: victim.runner);
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
    _emit(ExecutionEventKind.acquired, request, lane, executionId, runner: runner);
    return ExecutionLease._(this, executionId, request, lane, runner, runnerId);
  }

  Future<void> _release(int executionId, {bool forceQuarantine = false}) async {
    final active = _active[executionId];
    if (active == null) return;
    final runner = active.runner;
    var quarantine = false;
    if (runner != null && active.lane == ExecutionLane.worker) {
      if (!_closing && runner.isReusable && runner.harness.state == WorkerState.idle) {
        _cache.add(
          _CachedWorker(
            runner: runner,
            fingerprint: active.request.fingerprint,
            lastSessionId: active.request.sessionId,
            lastUsed: DateTime.now(),
            request: active.request,
          ),
        );
        _emit(ExecutionEventKind.cached, active.request, active.lane, executionId, runner: runner);
      } else {
        await _disposeWorker(runner, active.request, executionId: executionId);
        quarantine = !runner.harness.isRootProcessTerminationConfirmed;
      }
    }

    if (quarantine || forceQuarantine) {
      active.permit.quarantine();
      _emit(ExecutionEventKind.quarantined, active.request, active.lane, executionId, runner: runner);
    } else {
      active.permit.release();
    }
    _active.remove(executionId);
    try {
      _releaseAdmission?.call(active.request.sessionId);
    } finally {
      _emit(ExecutionEventKind.released, active.request, active.lane, executionId, runner: runner);
      _completeDrainIfIdle();
    }
  }

  Future<void> _disposeWorker(TurnRunner runner, ExecutionRequest request, {required int executionId}) async {
    try {
      await runner.harness.stop();
    } catch (error, stackTrace) {
      _log.warning('Failed to stop worker harness', error, stackTrace);
    }
    try {
      await runner.harness.dispose();
    } catch (error, stackTrace) {
      _log.warning('Failed to dispose worker harness', error, stackTrace);
    }
    _emit(ExecutionEventKind.disposed, request, ExecutionLane.worker, executionId, runner: runner);
    runner.setOutcomeObserver(null);
    _runnerIds.remove(runner);
  }

  Future<void> resetSessionContinuity(String sessionId, {bool workersOnly = false}) async {
    final relevantRunners = runners.where((runner) => !workersOnly || !identical(runner, _primary)).toList();
    _ActiveExecution? busyExecution;
    for (final execution in _active.values) {
      if (execution.runner != null && (!workersOnly || !identical(execution.runner, _primary))) {
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
    for (final runner in relevantRunners) {
      await runner.resetSessionContinuity(sessionId);
    }
    _forgetOutcomesForSession(sessionId);
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

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
      await _disposeWorker(worker.runner, worker.request, executionId: 0);
    }
    _cache.clear();
    final primary = _primary;
    if (primary != null) {
      try {
        await primary.harness.stop();
      } catch (error, stackTrace) {
        _log.warning('Failed to stop primary harness', error, stackTrace);
      }
      try {
        await primary.harness.dispose();
      } catch (error, stackTrace) {
        _log.warning('Failed to dispose primary harness', error, stackTrace);
      }
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

ExecutionFingerprint _defaultFingerprint(String providerId, String profileId) =>
    ExecutionFingerprint(providerId: providerId, profileId: profileId, configurationId: 'runtime');

final class ExecutionLease {
  ExecutionLease._(this._coordinator, this.executionId, this.request, this.lane, this.runner, this.runnerId);

  final ExecutionCoordinator _coordinator;
  final int executionId;
  final ExecutionRequest request;
  final ExecutionLane lane;
  final TurnRunner? runner;
  final int? runnerId;
  bool get admissionOwned => _coordinator.ownsAdmission;
  Future<void>? _releaseFuture;

  Future<void> release() => _releaseFuture ??= _coordinator._release(executionId);

  /// Permanently removes a capacity-only slot when caller-managed teardown cannot be confirmed.
  Future<void> quarantine() {
    if (lane != ExecutionLane.capacityOnly) {
      throw StateError('Only capacity-only leases may be quarantined by their caller');
    }
    return _releaseFuture ??= _coordinator._release(executionId, forceQuarantine: true);
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
    required this.fingerprint,
    required this.lastSessionId,
    required this.lastUsed,
    required this.request,
  });

  final TurnRunner runner;
  final ExecutionFingerprint fingerprint;
  final String lastSessionId;
  final DateTime lastUsed;
  final ExecutionRequest request;
}
