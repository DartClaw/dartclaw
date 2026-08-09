import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Provisions a task runner for the requested provider, when supplied.
typedef SpawnTaskRunner = Future<bool> Function(String? requestedProviderId);

typedef ProviderUnavailableDiagnostic = void Function(Task task, String message);

/// Coordinates task-runner acquisition from the harness pool.
final class TaskRunnerPoolCoordinator {
  TaskRunnerPoolCoordinator({
    required HarnessPool pool,
    SpawnTaskRunner? onSpawnNeeded,
    ProviderUnavailableDiagnostic? onProviderUnavailable,
    Logger? log,
  }) : _pool = pool,
       _onSpawnNeeded = onSpawnNeeded,
       _onProviderUnavailable = onProviderUnavailable,
       _log = log ?? Logger('TaskRunnerPoolCoordinator');

  final HarnessPool _pool;
  final SpawnTaskRunner? _onSpawnNeeded;
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

  /// Acquires an idle [providerId] runner, provisioning capacity when needed.
  Future<TurnRunner?> provisionAndAcquireProvider(String providerId) async {
    while (true) {
      final runner = _pool.tryAcquireForProvider(providerId);
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
      if (!_pool.hasTaskRunnerForProvider(provider)) {
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
              ? 'Task ${task.id} (${task.title}) is queued while provisioning a task runner for provider '
                    '"$provider". Available providers: ${_pool.taskProviders.join(', ')}'
              : 'Task ${task.id} (${task.title}) is queued but no task runner is configured for provider '
                    '"$provider". Available providers: ${_pool.taskProviders.join(', ')}',
          level: provisioning ? Level.INFO : Level.WARNING,
        );
        return null;
      }

      final exactMatch = _pool.tryAcquireForProviderAndProfile(provider, profile);
      if (exactMatch != null) {
        return exactMatch;
      }

      if (profile != 'workspace' && _pool.taskProfiles.length == 1 && _pool.taskProfiles.contains('workspace')) {
        final workspaceFallback = _pool.tryAcquireForProvider(provider);
        if (workspaceFallback != null) {
          if (_runnerWaitLoggedTaskIds.add(task.id)) {
            _log.info(
              'Task ${task.id} (${task.title}) requested profile "$profile" for provider "$provider", '
              'but only workspace task runners are available. Falling back to the workspace runner.',
            );
          }
          return workspaceFallback;
        }
      }

      _logRunnerWaitOnce(
        task,
        'Task ${task.id} (${task.title}) is queued waiting for an idle task runner for provider '
        '"$provider" in profile "$profile". Available profiles: ${_pool.taskProfiles.join(', ')}',
      );
      if (!_isSpawning && _pool.spawnableCount > 0) {
        triggerSpawn(provider);
      }
      return null;
    }
    if (_pool.hasTaskRunnerForProfile(profile)) {
      return _pool.tryAcquireForProfile(profile);
    }
    if (_pool.taskProfiles.length <= 1) {
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
          _log.warning('Task-runner provisioning failed', error, stackTrace);
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
