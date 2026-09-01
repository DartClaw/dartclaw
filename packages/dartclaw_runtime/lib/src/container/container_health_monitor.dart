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
  new({
    required EventBus eventBus,
    this.interval = const Duration(seconds: 10),
    this.healthCheckTimeout = const Duration(seconds: 5),
  }) : _eventBus = eventBus;

  static final _log = Logger('ContainerHealthMonitor');

  final EventBus _eventBus;
  final Duration interval;
  final Duration healthCheckTimeout;

  final Map<String, ContainerManager> _watched = {};
  final Map<String, bool> _lastHealthy = {};
  final Map<String, String> _taskIds = {};
  final Map<String, Future<ContainerHealth>> _healthRequests = {};
  Timer? _timer;
  Future<void>? _healthCheck;

  /// Container names currently monitored.
  Iterable<String> get watchedContainers => _watched.keys;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => _scheduleHealthCheck());
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
    await _healthCheck;
  }

  void _scheduleHealthCheck() {
    if (_healthCheck != null) return;
    final check = _checkHealth();
    _healthCheck = check;
    unawaited(
      check.then<void>(
        (_) {
          if (identical(_healthCheck, check)) _healthCheck = null;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_healthCheck, check)) _healthCheck = null;
          _log.warning('Container health poll failed', error, stackTrace);
        },
      ),
    );
  }

  Future<void> _checkHealth() async {
    for (final entry in _watched.entries.toList()) {
      final containerName = entry.key;
      final manager = entry.value;
      try {
        if (!_watched.containsKey(containerName)) continue;
        final health = await _boundedHealth(containerName, manager);
        if (health == null) continue;
        // Release can unwatch while this check is in flight; a container that
        // is no longer ours must not produce an event.
        if (!_watched.containsKey(containerName)) continue;
        // A daemon blip or inspect error is not a crash: hold the last known
        // state so one transient failure cannot fail every watched execution.
        if (health == ContainerHealth.unknown) continue;
        final wasHealthy = _lastHealthy[containerName] ?? true;
        final healthy = health == ContainerHealth.running;

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

  Future<ContainerHealth?> _boundedHealth(String containerName, ContainerManager manager) async {
    if (_healthRequests.containsKey(containerName)) return null;
    final request = manager.health();
    _healthRequests[containerName] = request;
    unawaited(
      request.then<void>(
        (_) {
          if (identical(_healthRequests[containerName], request)) _healthRequests.remove(containerName);
        },
        onError: (Object _, StackTrace _) {
          if (identical(_healthRequests[containerName], request)) _healthRequests.remove(containerName);
        },
      ),
    );
    try {
      return await request.timeout(healthCheckTimeout);
    } on TimeoutException {
      _log.warning('Health check timed out for container $containerName after $healthCheckTimeout');
      return null;
    }
  }
}
