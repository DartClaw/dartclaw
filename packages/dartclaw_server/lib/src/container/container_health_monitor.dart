import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerCrashedEvent, ContainerStartedEvent, EventBus;
import 'package:logging/logging.dart';

import 'container_manager.dart';

/// Periodically checks container health and fires lifecycle events on state transitions.
///
/// Detects container crashes (healthy → unhealthy) and recoveries (unhealthy → healthy).
/// Tasks in a crashed container will fail naturally when their `docker exec` subprocess
/// terminates, but this monitor provides structured event notification.
class ContainerHealthMonitor {
  static final _log = Logger('ContainerHealthMonitor');

  final Map<String, ContainerManager> _containerManagers;
  final EventBus _eventBus;
  final Duration interval;

  Timer? _timer;
  final Map<String, bool> _lastHealthy = {};

  ContainerHealthMonitor({
    required Map<String, ContainerManager> containerManagers,
    required EventBus eventBus,
    this.interval = const Duration(seconds: 10),
  }) : _containerManagers = containerManagers,
       _eventBus = eventBus;

  void start() {
    if (_timer != null) return;
    // Initialize health state as healthy for all known containers.
    for (final entry in _containerManagers.entries) {
      _lastHealthy[entry.key] = true;
    }
    _timer = Timer.periodic(interval, (_) {
      unawaited(_checkHealth());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _checkHealth() async {
    for (final entry in _containerManagers.entries) {
      final profileId = entry.key;
      final manager = entry.value;
      try {
        final healthy = await manager.isHealthy();
        final wasHealthy = _lastHealthy[profileId] ?? true;

        if (wasHealthy && !healthy) {
          _log.severe('Container crashed: profile=$profileId, container=${manager.containerName}');
          _eventBus.fire(
            ContainerCrashedEvent(
              profileId: profileId,
              containerName: manager.containerName,
              error: 'Container is no longer running',
              timestamp: DateTime.now(),
            ),
          );
        } else if (!wasHealthy && healthy) {
          _log.info('Container recovered: profile=$profileId, container=${manager.containerName}');
          _eventBus.fire(
            ContainerStartedEvent(
              profileId: profileId,
              containerName: manager.containerName,
              timestamp: DateTime.now(),
            ),
          );
        }

        _lastHealthy[profileId] = healthy;
      } catch (e) {
        _log.warning('Health check failed for profile $profileId: $e');
      }
    }
  }
}
