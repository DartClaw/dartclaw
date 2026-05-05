import 'package:logging/logging.dart';

import 'config_delta.dart';
import 'dartclaw_config.dart';
import 'reconfigurable.dart';

final _log = Logger('ConfigNotifier');

/// Reactive configuration holder for Live Config Tier 3 (hot-reload).
///
/// Holds the current [DartclawConfig], computes section-level [ConfigDelta]
/// on [reload], and notifies registered [Reconfigurable] services filtered
/// to each service's [Reconfigurable.watchKeys].
///
/// Best-effort model: if a service's [Reconfigurable.reconfigure] throws,
/// the error is logged and remaining services continue to be notified.
class ConfigNotifier {
  /// Field keys that cannot be reloaded at runtime without a server restart.
  static const Set<String> nonReloadableKeys = {
    'server.port',
    'server.host',
    'server.data_dir',
    'andthen.git_url',
    'andthen.ref',
    'andthen.network',
    'andthen.source_cache_dir',
  };

  DartclawConfig _current;
  final List<Reconfigurable> _services = [];

  ConfigNotifier(DartclawConfig initial) : _current = initial;

  /// The current configuration.
  DartclawConfig get current => _current;

  /// Register a [Reconfigurable] service to receive config change notifications.
  ///
  /// Registering the same instance twice has no effect.
  void register(Reconfigurable service) {
    if (!_services.contains(service)) {
      _services.add(service);
    }
  }

  /// Unregister a previously registered [Reconfigurable] service.
  void unregister(Reconfigurable service) {
    _services.remove(service);
  }

  /// Apply [newConfig] as the current configuration and notify services.
  ///
  /// Computes a section-level [ConfigDelta] by comparing each top-level config
  /// section using `==`. Changed sections add `sectionName.*` to [ConfigDelta.changedKeys].
  ///
  /// Non-reloadable fields ([nonReloadableKeys]) are checked: if changed, a
  /// warning is logged. If the entire server section only changed non-reloadable
  /// fields, `server.*` is excluded from [ConfigDelta.changedKeys].
  ///
  /// Returns `null` when no reloadable fields changed (no services are notified).
  ConfigDelta? reload(DartclawConfig newConfig) {
    final old = _current;
    final changedKeys = <String>{};

    _detectChanged('server', old.server, newConfig.server, changedKeys, old, newConfig);
    _detectChangedSimple('agent', old.agent, newConfig.agent, changedKeys);
    _detectChangedSimple('advisor', old.advisor, newConfig.advisor, changedKeys);
    _detectChangedSimple('auth', old.auth, newConfig.auth, changedKeys);
    _detectChangedSimple('canvas', old.canvas, newConfig.canvas, changedKeys);
    _detectChangedSimple('gateway', old.gateway, newConfig.gateway, changedKeys);
    _detectChangedSimple('sessions', old.sessions, newConfig.sessions, changedKeys);
    _detectChangedSimple('context', old.context, newConfig.context, changedKeys);
    _detectChangedSimple('security', old.security, newConfig.security, changedKeys);
    _detectChangedSimple('memory', old.memory, newConfig.memory, changedKeys);
    _detectChangedSimple('search', old.search, newConfig.search, changedKeys);
    _detectChangedSimple('providers', old.providers, newConfig.providers, changedKeys);
    _detectChangedSimple('credentials', old.credentials, newConfig.credentials, changedKeys);
    _detectChangedSimple('tasks', old.tasks, newConfig.tasks, changedKeys);
    _detectChangedSimple('scheduling', old.scheduling, newConfig.scheduling, changedKeys);
    _detectChangedSimple('workspace', old.workspace, newConfig.workspace, changedKeys);
    _detectChangedSimple('logging', old.logging, newConfig.logging, changedKeys);
    _detectChangedSimple('usage', old.usage, newConfig.usage, changedKeys);
    _detectChangedSimple('container', old.container, newConfig.container, changedKeys);
    _detectChangedSimple('channels', old.channels, newConfig.channels, changedKeys);
    _detectChangedSimple('governance', old.governance, newConfig.governance, changedKeys);
    _detectChangedSimple('features', old.features, newConfig.features, changedKeys);
    _detectChangedSimple('projects', old.projects, newConfig.projects, changedKeys);
    if (old.andthen != newConfig.andthen) {
      _log.warning(
        'ConfigNotifier: reload contains non-reloadable andthen.* changes — '
        'restart `dartclaw serve` to pick up new clone/install settings.',
      );
    }

    if (changedKeys.isEmpty) return null;

    _current = newConfig;
    final delta = ConfigDelta(previous: old, current: newConfig, changedKeys: Set.unmodifiable(changedKeys));

    for (final service in List.of(_services)) {
      if (!delta.hasChangedAny(service.watchKeys)) continue;
      try {
        service.reconfigure(delta);
      } catch (e, st) {
        _log.severe(
          'ConfigNotifier: ${service.runtimeType}.reconfigure() threw — continuing with other services',
          e,
          st,
        );
      }
    }

    return delta;
  }

  /// Compares the `server` section specially: non-reloadable field changes
  /// are logged as warnings and excluded from [changedKeys] unless the
  /// section has other changes too.
  void _detectChanged(
    String section,
    Object? oldVal,
    Object? newVal,
    Set<String> changedKeys,
    DartclawConfig old,
    DartclawConfig newConfig,
  ) {
    if (oldVal == newVal) return;

    // Check non-reloadable fields for the server section.
    final nonReloadableChanged = <String>{};
    if (old.server.port != newConfig.server.port) nonReloadableChanged.add('server.port');
    if (old.server.host != newConfig.server.host) nonReloadableChanged.add('server.host');
    if (old.server.dataDir != newConfig.server.dataDir) nonReloadableChanged.add('server.data_dir');

    if (nonReloadableChanged.isNotEmpty) {
      _log.warning(
        'ConfigNotifier: reload contains non-reloadable field changes: '
        '${nonReloadableChanged.join(', ')} — changes to these fields require a server restart.',
      );
    }

    // Check if the server section has any reloadable changes beyond the non-reloadable ones.
    // Build a "server with non-reloadable fields reset to old values" and compare.
    final hasReloadableServerChanges = _serverHasReloadableChanges(old.server, newConfig.server);

    if (hasReloadableServerChanges) {
      changedKeys.add('$section.*');
    } else if (nonReloadableChanged.isNotEmpty) {
      // Only non-reloadable fields changed — do not add to changedKeys.
      _log.warning(
        'ConfigNotifier: server section only changed non-reloadable fields — '
        'excluding server.* from delta.',
      );
    } else {
      changedKeys.add('$section.*');
    }
  }

  bool _serverHasReloadableChanges(dynamic old, dynamic newVal) {
    // Compare fields other than port, host, dataDir.
    return old.name != newVal.name ||
        old.baseUrl != newVal.baseUrl ||
        old.workerTimeout != newVal.workerTimeout ||
        old.claudeExecutable != newVal.claudeExecutable ||
        old.staticDir != newVal.staticDir ||
        old.templatesDir != newVal.templatesDir ||
        old.devMode != newVal.devMode ||
        old.maxParallelTurns != newVal.maxParallelTurns;
  }

  void _detectChangedSimple(String section, Object? oldVal, Object? newVal, Set<String> changedKeys) {
    if (oldVal != newVal) changedKeys.add('$section.*');
  }
}
