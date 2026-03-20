import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

import '../behavior/heartbeat_scheduler.dart';
import '../context/context_monitor.dart';
import '../runtime_config.dart';
import '../workspace/workspace_git_sync.dart';

/// Subscribes to [ConfigChangedEvent] and applies live config side-effects.
///
/// Replaces the inline `switch` statement that was in `config_api_routes.dart`.
class ConfigChangeSubscriber {
  final RuntimeConfig runtimeConfig;
  final HeartbeatScheduler? heartbeat;
  final WorkspaceGitSync? gitSync;
  final ContextMonitor? contextMonitor;
  StreamSubscription<ConfigChangedEvent>? _subscription;

  ConfigChangeSubscriber({required this.runtimeConfig, this.heartbeat, this.gitSync, this.contextMonitor});

  /// Start listening on the given [EventBus].
  void subscribe(EventBus bus) {
    _subscription = bus.on<ConfigChangedEvent>().listen(_onConfigChanged);
  }

  void _onConfigChanged(ConfigChangedEvent event) {
    for (final key in event.changedKeys) {
      final value = event.newValues[key];
      switch (key) {
        case 'scheduling.heartbeat.enabled':
          final enabled = value as bool;
          if (enabled) {
            heartbeat?.start();
          } else {
            heartbeat?.stop();
          }
          runtimeConfig.heartbeatEnabled = enabled;
        case 'workspace.git_sync.enabled':
          runtimeConfig.gitSyncEnabled = value as bool;
        case 'workspace.git_sync.push_enabled':
          final enabled = value as bool;
          if (gitSync != null) gitSync!.pushEnabled = enabled;
          runtimeConfig.gitSyncPushEnabled = enabled;
        case 'context.warning_threshold':
          if (value is int) {
            final clamped = value.clamp(50, 99);
            if (contextMonitor != null) contextMonitor!.warningThreshold = clamped;
          }
      }
    }
  }

  /// Cancel the subscription.
  Future<void> cancel() async {
    await _subscription?.cancel();
  }
}
