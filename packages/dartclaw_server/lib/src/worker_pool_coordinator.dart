import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Provisions a worker for the requested provider, when supplied.
typedef SpawnWorker = Future<bool> Function(String? requestedProviderId);

typedef ProviderUnavailableDiagnostic = void Function(Task task, String message);

/// Coordinates worker acquisition and lazy provisioning from the harness pool.
final class WorkerPoolCoordinator {
  WorkerPoolCoordinator({
    required HarnessPool pool,
    SpawnWorker? onSpawnNeeded,
    ProviderUnavailableDiagnostic? onProviderUnavailable,
    Logger? log,
  }) : _pool = pool,
       _onSpawnNeeded = onSpawnNeeded,
       _onProviderUnavailable = onProviderUnavailable,
       _log = log ?? Logger('WorkerPoolCoordinator');

  final HarnessPool _pool;
  final SpawnWorker? _onSpawnNeeded;
  ProviderUnavailableDiagnostic? _onProviderUnavailable;
  final Logger _log;
  final Set<String> _runnerWaitLoggedTaskIds = <String>{};
  final Set<String> _providerUnavailableTaskIds = <String>{};
  Future<bool>? _inFlightProvision;
  String? _inFlightProviderId;

  bool get _isSpawning => _inFlightProvision != null;

  void setProviderUnavailableDiagnostic(ProviderUnavailableDiagnostic? diagnostic) {
    _onProviderUnavailable = diagnostic;
  }

  /// Acquires an idle [providerId] runner, optionally constrained to [profileId],
  /// provisioning capacity when needed.
  Future<TurnRunner?> provisionAndAcquireProvider(String providerId, {String? profileId}) async {
    while (true) {
      final runner = profileId == null
          ? _pool.tryAcquireForProvider(providerId)
          : _pool.tryAcquireForProviderAndProfile(providerId, profileId);
      if (runner != null) return runner;
      if (_pool.spawnableCount <= 0) return null;
      final joinedDifferentProvider = _inFlightProvision != null && _inFlightProviderId != providerId;
      final spawned = await _provision(providerId);
      if (!spawned && !joinedDifferentProvider) return null;
    }
  }

  void triggerSpawnIfNeeded([String? requestedProviderId]) {
    if (_pool.availableCount == 0 && _pool.spawnableCount > 0 && !_isSpawning) {
      triggerSpawn(requestedProviderId);
    }
  }

  TurnRunner? acquireRunnerForTask(Task task, String profile, {String? effectiveProviderId}) {
    final provider = effectiveProviderId ?? task.provider;
    if (provider != null) {
      if (!_pool.hasWorkerForProvider(provider)) {
        final canSpawn = !_isSpawning && _pool.spawnableCount > 0;
        final provisioning = _isSpawning || canSpawn;
        if (canSpawn) {
          triggerSpawn(provider, onNoRunnerSpawned: () => _recordProviderUnavailable(task, provider));
        } else if (!provisioning) {
          _recordProviderUnavailable(task, provider);
        }
        _logRunnerWaitOnce(
          task,
          provisioning
              ? 'Task ${task.id} (${task.title}) is queued while provisioning a worker for provider '
                    '"$provider". Available providers: ${_pool.workerProviders.join(', ')}'
              : 'Task ${task.id} (${task.title}) is queued but no worker is configured for provider '
                    '"$provider". Available providers: ${_pool.workerProviders.join(', ')}',
          level: provisioning ? Level.INFO : Level.WARNING,
        );
        return null;
      }

      final exactMatch = _pool.tryAcquireForProviderAndProfile(provider, profile);
      if (exactMatch != null) {
        return exactMatch;
      }

      _logRunnerWaitOnce(
        task,
        'Task ${task.id} (${task.title}) is queued waiting for an idle worker for provider '
        '"$provider" in profile "$profile". Available profiles: ${_pool.workerProfiles.join(', ')}',
      );
      if (!_isSpawning && _pool.spawnableCount > 0) {
        triggerSpawn(provider);
      }
      return null;
    }
    if (_pool.hasWorkerForProfile(profile)) {
      return _pool.tryAcquireForProfile(profile);
    }
    if (_pool.workerProfiles.length <= 1) {
      return _pool.tryAcquire();
    }
    return null;
  }

  void clearWaitLog(String taskId) {
    _runnerWaitLoggedTaskIds.remove(taskId);
    _providerUnavailableTaskIds.remove(taskId);
  }

  void triggerSpawn(String? requestedProviderId, {void Function()? onNoRunnerSpawned}) {
    unawaited(
      _provision(requestedProviderId).then((spawned) {
        if (!spawned) {
          onNoRunnerSpawned?.call();
        }
      }),
    );
  }

  Future<bool> _provision(String? requestedProviderId) {
    final active = _inFlightProvision;
    if (active != null) return active;
    final callback = _onSpawnNeeded;
    if (callback == null) return Future<bool>.value(false);
    _inFlightProviderId = requestedProviderId;
    late final Future<bool> provision;
    provision = callback(requestedProviderId)
        .catchError((Object error, StackTrace stackTrace) {
          _log.warning('Worker provisioning failed', error, stackTrace);
          return false;
        })
        .whenComplete(() {
          if (identical(_inFlightProvision, provision)) {
            _inFlightProvision = null;
            _inFlightProviderId = null;
          }
        });
    _inFlightProvision = provision;
    return provision;
  }

  void _logRunnerWaitOnce(Task task, String message, {Level level = Level.WARNING}) {
    if (_runnerWaitLoggedTaskIds.add(task.id)) {
      _log.log(level, message);
    }
  }

  void _recordProviderUnavailable(Task task, String provider) {
    if (!_providerUnavailableTaskIds.add(task.id)) {
      return;
    }
    _onProviderUnavailable?.call(
      task,
      'Provider "$provider" is unavailable for task execution. Configure providers.$provider before retrying.',
    );
  }
}
