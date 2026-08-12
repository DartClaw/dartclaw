import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerCrashedEvent, ContainerStartedEvent, EventBus;
import 'package:logging/logging.dart';

import 'container_manager.dart';

/// Periodically checks container health and fires lifecycle events on state transitions.
///
/// Monitoring is keyed by container name — one entry per live authority, not
/// per profile — and an authority is unwatched *before* its teardown begins.
/// A normal release must never be reported as a crash: crash attribution is
/// what tells an operator an isolated execution died unexpectedly.
class ContainerHealthMonitor {
  ContainerHealthMonitor({required EventBus eventBus, this.interval = const Duration(seconds: 10)})
    : _eventBus = eventBus;

  static final _log = Logger('ContainerHealthMonitor');

  final EventBus _eventBus;
  final Duration interval;

  final Map<String, ContainerManager> _watched = {};
  final Map<String, bool> _lastHealthy = {};
  final Map<String, String> _taskIds = {};
  Timer? _timer;

  /// Container names currently monitored.
  Iterable<String> get watchedContainers => _watched.keys;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      unawaited(_checkHealth());
    });
  }

  /// Begins monitoring one live authority's container.
  ///
  /// [taskId] identifies the execution the authority was leased for, so a crash
  /// is attributed to that execution alone rather than to every task sharing
  /// its profile.
  void watch(String containerName, ContainerManager manager, {String? taskId}) {
    _watched[containerName] = manager;
    _lastHealthy[containerName] = true;
    if (taskId != null) _taskIds[containerName] = taskId;
  }

  /// Stops monitoring a container. Call before teardown, not after.
  void unwatch(String containerName) {
    _watched.remove(containerName);
    _lastHealthy.remove(containerName);
    _taskIds.remove(containerName);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _watched.clear();
    _lastHealthy.clear();
    _taskIds.clear();
  }

  Future<void> _checkHealth() async {
    for (final entry in _watched.entries.toList()) {
      final containerName = entry.key;
      final manager = entry.value;
      try {
        final healthy = await manager.isHealthy();
        // Release can unwatch while this check is in flight; a container that
        // is no longer ours must not produce an event.
        if (!_watched.containsKey(containerName)) continue;
        final wasHealthy = _lastHealthy[containerName] ?? true;

        if (wasHealthy && !healthy) {
          _log.severe('Container crashed: profile=${manager.profileId}, container=$containerName');
          _eventBus.fire(
            ContainerCrashedEvent(
              profileId: manager.profileId,
              containerName: containerName,
              error: 'Container is no longer running',
              timestamp: DateTime.now(),
              taskId: _taskIds[containerName],
            ),
          );
        } else if (!wasHealthy && healthy) {
          _log.info('Container recovered: profile=${manager.profileId}, container=$containerName');
          _eventBus.fire(
            ContainerStartedEvent(
              profileId: manager.profileId,
              containerName: containerName,
              timestamp: DateTime.now(),
            ),
          );
        }

        _lastHealthy[containerName] = healthy;
      } catch (e) {
        _log.warning('Health check failed for container $containerName: $e');
      }
    }
  }
}
