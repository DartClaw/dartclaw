import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

import '../context/context_monitor.dart';
import '../runtime_config.dart';
import '../scheduling/schedule_service.dart';
import '../workspace/workspace_git_sync.dart';
import 'runtime_toggle_applier.dart';

/// Subscribes to [ConfigChangedEvent] and applies live config side-effects.
///
/// Only `PATCH /api/config` delivers exact dotted keys here — `ConfigNotifier`
/// emits section wildcards to [Reconfigurable]s instead — so a key that must
/// take effect at runtime has to be declared `live` in `ConfigMeta` and handled
/// in this switch.
class ConfigChangeSubscriber {
  final RuntimeConfig runtimeConfig;
  final ScheduleService? scheduleService;
  final WorkspaceGitSync? gitSync;
  final ContextMonitor? contextMonitor;
  StreamSubscription<ConfigChangedEvent>? _subscription;

  late final RuntimeToggleApplier _toggles = RuntimeToggleApplier(
    runtimeConfig: runtimeConfig,
    scheduleService: scheduleService,
    gitSync: gitSync,
  );

  new({required this.runtimeConfig, this.scheduleService, this.gitSync, this.contextMonitor});

  /// Start listening on the given [EventBus].
  void subscribe(EventBus bus) {
    _subscription = bus.on<ConfigChangedEvent>().listen(_onConfigChanged);
  }

  void _onConfigChanged(ConfigChangedEvent event) {
    for (final key in event.changedKeys) {
      final value = event.newValues[key];
      switch (key) {
        case 'scheduling.heartbeat.enabled':
          _toggles.setHeartbeatEnabled(value as bool);
        case 'workspace.git_sync.enabled':
          _toggles.setGitSyncEnabled(value as bool);
        case 'workspace.git_sync.push_enabled':
          _toggles.setGitSyncPushEnabled(value as bool);
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
