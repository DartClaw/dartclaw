import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../harness_pool.dart';
import '../turn_runner.dart';

/// Coordinates task-runner acquisition from the harness pool.
final class TaskRunnerPoolCoordinator {
  TaskRunnerPoolCoordinator({required HarnessPool pool, Future<void> Function()? onSpawnNeeded, Logger? log})
    : _pool = pool,
      _onSpawnNeeded = onSpawnNeeded,
      _log = log ?? Logger('TaskRunnerPoolCoordinator');

  final HarnessPool _pool;
  final Future<void> Function()? _onSpawnNeeded;
  final Logger _log;
  final Set<String> _runnerWaitLoggedTaskIds = <String>{};
  bool _isSpawning = false;

  void triggerSpawnIfNeeded() {
    if (_pool.availableCount == 0 && _pool.spawnableCount > 0 && !_isSpawning) {
      triggerSpawn();
    }
  }

  TurnRunner? acquireRunnerForTask(Task task, String profile) {
    final provider = task.provider;
    if (provider != null) {
      if (!_pool.hasTaskRunnerForProvider(provider)) {
        final provisioning = _isSpawning || _pool.spawnableCount > 0;
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
  }

  void triggerSpawn() {
    final callback = _onSpawnNeeded;
    if (callback == null) return;
    _isSpawning = true;
    unawaited(
      callback().whenComplete(() {
        _isSpawning = false;
      }),
    );
  }

  void _logRunnerWaitOnce(Task task, String message, {Level level = Level.WARNING}) {
    if (_runnerWaitLoggedTaskIds.add(task.id)) {
      _log.log(level, message);
    }
  }
}
