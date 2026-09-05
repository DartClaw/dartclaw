import 'package:logging/logging.dart';

import 'config_delta.dart';
import 'dartclaw_config.dart';
import 'platform_capabilities.dart';
import 'reconfigurable.dart';
import 'server_config.dart';

final _log = Logger('ConfigNotifier');

/// Reload tier declared for a [DartclawConfig] section.
///
/// Every composed section carries exactly one tier; the fitness suite fails
/// when a section is added to [DartclawConfig] without one.
enum ConfigReloadTier {
  /// Compared on every reload; a change rides the [ConfigDelta] to the
  /// services watching the section.
  reloadable,

  /// Compared on every reload; a change is reported through
  /// [ConfigNotifier.restartRequiredSections] and withheld from the delta.
  /// No [Reconfigurable] may register a watch key resolving to such a section.
  restart,
}

typedef _Section = ({ConfigReloadTier tier, Object? Function(DartclawConfig config) read});

/// Reactive configuration holder for Live Config Tier 3 (hot-reload).
///
/// Holds the current [DartclawConfig], computes section-level [ConfigDelta]
/// on [reload], and notifies registered [Reconfigurable] services filtered
/// to each service's [Reconfigurable.watchKeys].
///
/// Best-effort model: if a service's [Reconfigurable.reconfigure] throws,
/// the error is logged and remaining services continue to be notified.
class ConfigNotifier {
  /// Server fields that cannot be reloaded at runtime without a restart, keyed
  /// by the YAML path the operator sees. Both the warning that names them and
  /// the carry-forward of their old values read this one map.
  static final Map<String, Object? Function(ServerConfig server)> _nonReloadableServerFields = {
    'server.port': (server) => server.port,
    'server.host': (server) => server.host,
    'server.data_dir': (server) => server.dataDir,
  };

  /// Declared reload tier per [DartclawConfig] section, keyed by the field name
  /// on [DartclawConfig] — not the YAML top-level key. The two namespaces
  /// differ (YAML `guards:` parses into `security`, YAML `concurrency:` into
  /// `server`), and [ConfigDelta.changedKeys] and [Reconfigurable.watchKeys]
  /// both already use this one.
  ///
  /// A section is [ConfigReloadTier.reloadable] only while some registered
  /// service genuinely applies its changes; everything else is
  /// [ConfigReloadTier.restart]. `extensions` is deliberately absent: it is a
  /// `Map<String, Object?>` of deployer-registered sections with no value
  /// equality, so `!=` between two parses is always true.
  static final Map<String, _Section> _sections = {
    'server': (tier: ConfigReloadTier.reloadable, read: (config) => config.server),
    'agent': (tier: ConfigReloadTier.restart, read: (config) => config.agent),
    'auth': (tier: ConfigReloadTier.restart, read: (config) => config.auth),
    'gateway': (tier: ConfigReloadTier.restart, read: (config) => config.gateway),
    'harness': (tier: ConfigReloadTier.restart, read: (config) => config.harness),
    'sessions': (tier: ConfigReloadTier.reloadable, read: (config) => config.sessions),
    'context': (tier: ConfigReloadTier.reloadable, read: (config) => config.context),
    'security': (tier: ConfigReloadTier.reloadable, read: (config) => config.security),
    'memory': (tier: ConfigReloadTier.restart, read: (config) => config.memory),
    'knowledge': (tier: ConfigReloadTier.restart, read: (config) => config.knowledge),
    'search': (tier: ConfigReloadTier.restart, read: (config) => config.search),
    'mcpServers': (tier: ConfigReloadTier.restart, read: (config) => config.mcpServers),
    'providers': (tier: ConfigReloadTier.restart, read: (config) => config.providers),
    'credentials': (tier: ConfigReloadTier.restart, read: (config) => config.credentials),
    'tasks': (tier: ConfigReloadTier.restart, read: (config) => config.tasks),
    'scheduling': (tier: ConfigReloadTier.restart, read: (config) => config.scheduling),
    'workspace': (tier: ConfigReloadTier.reloadable, read: (config) => config.workspace),
    'onboarding': (tier: ConfigReloadTier.restart, read: (config) => config.onboarding),
    'workflow': (tier: ConfigReloadTier.restart, read: (config) => config.workflow),
    'logging': (tier: ConfigReloadTier.reloadable, read: (config) => config.logging),
    'usage': (tier: ConfigReloadTier.restart, read: (config) => config.usage),
    'container': (tier: ConfigReloadTier.restart, read: (config) => config.container),
    'channels': (tier: ConfigReloadTier.restart, read: (config) => config.channels),
    'governance': (tier: ConfigReloadTier.restart, read: (config) => config.governance),
    'features': (tier: ConfigReloadTier.restart, read: (config) => config.features),
    'projects': (tier: ConfigReloadTier.restart, read: (config) => config.projects),
    'alerts': (tier: ConfigReloadTier.reloadable, read: (config) => config.alerts),
  };

  /// The declared reload tier of every [DartclawConfig] section.
  static Map<String, ConfigReloadTier> get sectionTiers =>
      Map.unmodifiable({for (final entry in _sections.entries) entry.key: entry.value.tier});

  DartclawConfig _current;
  Set<String> _restartRequiredSections = const {};
  final List<Reconfigurable> _services = [];
  final PlatformCapabilities _platformCapabilities;

  /// Parsers for the config sections this package does not own, run against a
  /// freshly loaded config before that config is judged admissible.
  ///
  /// A section parsed outside this package appends its warnings to the config's
  /// own sink when it is parsed, not when it is loaded. Without priming, an
  /// unparseable section carries no warning at the moment [reload] reads
  /// [DartclawConfig.reloadBlockingWarnings], and a reload that must be refused
  /// is accepted instead. Every primer must be idempotent per config instance.
  final List<void Function(DartclawConfig config)> _sectionPrimers;

  /// Creates a notifier with the platform policy used for reload admission.
  new(
    DartclawConfig initial, {
    PlatformCapabilities? platformCapabilities,
    List<void Function(DartclawConfig config)> sectionPrimers = const [],
  }) : _current = initial,
       _sectionPrimers = sectionPrimers,
       _platformCapabilities = platformCapabilities ?? PlatformCapabilities();

  /// The current configuration.
  DartclawConfig get current => _current;

  /// Sections changed by the most recent successful [reload] whose declared
  /// tier is [ConfigReloadTier.restart] — the change is persisted but only
  /// takes effect on the next start.
  ///
  /// Reflects that reload alone and is not a pending-restart ledger: a reload
  /// with no restart-tier change empties it, and a reload rejected by an
  /// admission guard leaves it untouched. The durable record of what is still
  /// waiting on a restart is the `restart.pending` marker.
  Set<String> get restartRequiredSections => _restartRequiredSections;

  /// Register a [Reconfigurable] service to receive config change notifications.
  ///
  /// Registering the same instance twice has no effect.
  ///
  /// Throws [ArgumentError] when a watch key names no declared section, or
  /// resolves to a section declared [ConfigReloadTier.restart]: neither delta is
  /// ever produced, so the watcher could never fire.
  void register(Reconfigurable service) {
    for (final key in service.watchKeys) {
      final section = key.split('.').first;
      final spec = _sections[section];
      if (spec == null) {
        throw ArgumentError.value(
          key,
          'watchKeys',
          '${service.runtimeType} cannot watch section "$section": no such section is declared on '
              'DartclawConfig, so no delta ever names it. Watch keys use the field name, not the '
              'YAML key (`security`, not `guards`)',
        );
      }
      if (spec.tier != ConfigReloadTier.restart) continue;
      throw ArgumentError.value(
        key,
        'watchKeys',
        '${service.runtimeType} cannot watch section "$section": it is declared '
            '${ConfigReloadTier.restart.name} tier, so its changes are reported through '
            'restartRequiredSections and never delivered as a delta',
      );
    }
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
  /// Compares every declared section using `==`. A changed
  /// [ConfigReloadTier.reloadable] section adds `sectionName.*` to
  /// [ConfigDelta.changedKeys]; a changed [ConfigReloadTier.restart] section is
  /// recorded in [restartRequiredSections] and withheld from the delta.
  ///
  /// Non-reloadable server fields (`server.port`, `server.host`,
  /// `server.data_dir`) are checked: if changed, a warning is logged. If the
  /// entire server section only changed non-reloadable fields, `server.*` is
  /// excluded from [ConfigDelta.changedKeys].
  ///
  /// Returns `null` when no reloadable fields changed (no services are notified).
  ConfigDelta? reload(DartclawConfig newConfig) {
    for (final prime in _sectionPrimers) {
      prime(newConfig);
    }
    final blockingDiagnostics = newConfig.reloadBlockingWarnings;
    if (blockingDiagnostics.isNotEmpty) {
      throw FormatException('config validation failed: ${blockingDiagnostics.join('; ')}');
    }
    if (!_platformCapabilities.containerIsolationAvailable && newConfig.container.enabled) {
      throw const UnsupportedCapabilityError(
        capability: 'container isolation',
        attemptedContext: 'live reload enabling container isolation on native Windows',
        remediation: 'Keep container.enabled false, or restart DartClaw on POSIX or inside WSL.',
      );
    }

    final old = _current;
    final changedKeys = <String>{};
    final restartRequired = <String>{};

    for (final entry in _sections.entries) {
      final section = entry.key;
      final spec = entry.value;
      if (spec.read(old) == spec.read(newConfig)) continue;
      switch (spec.tier) {
        case ConfigReloadTier.restart:
          restartRequired.add(section);
        case ConfigReloadTier.reloadable:
          if (section == 'server') {
            _detectChangedServer(section, changedKeys, old, newConfig);
          } else {
            changedKeys.add('$section.*');
          }
      }
    }

    _restartRequiredSections = Set.unmodifiable(restartRequired);
    if (restartRequired.isNotEmpty) {
      _log.warning(
        'ConfigNotifier: restart-tier sections changed: ${restartRequired.join(', ')} — '
        'the new values are persisted but only take effect after a restart.',
      );
    }
    if (changedKeys.isEmpty) return null;

    final restartFieldsChanged = _nonReloadableServerFields.values.any(
      (read) => read(old.server) != read(newConfig.server),
    );
    // The container posture is settled by a startup probe a reload cannot rerun,
    // and `container.*` is restart-tier, so the value in force is carried
    // forward rather than reverting to whatever the file declares — an unset
    // section re-parses as disabled and would silently un-resolve the posture.
    final reloaded = old.container == newConfig.container ? newConfig : newConfig.copyWith(container: old.container);
    final current = restartFieldsChanged
        ? reloaded.copyWith(
            server: ServerConfig(
              port: old.server.port,
              host: old.server.host,
              dataDir: old.server.dataDir,
              name: newConfig.server.name,
              baseUrl: newConfig.server.baseUrl,
              claudeExecutable: newConfig.server.claudeExecutable,
              staticDir: newConfig.server.staticDir,
              templatesDir: newConfig.server.templatesDir,
              devMode: newConfig.server.devMode,
              maxParallelTurns: newConfig.server.maxParallelTurns,
            ),
          )
        : reloaded;
    _current = current;
    final delta = ConfigDelta(previous: old, current: current, changedKeys: Set.unmodifiable(changedKeys));

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

  /// Resolves an already-detected `server` change: non-reloadable field changes
  /// are logged as warnings and excluded from [changedKeys] unless the
  /// section has other changes too.
  void _detectChangedServer(String section, Set<String> changedKeys, DartclawConfig old, DartclawConfig newConfig) {
    final nonReloadableChanged = _nonReloadableServerFields.entries
        .where((field) => field.value(old.server) != field.value(newConfig.server))
        .map((field) => field.key)
        .toList();

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

  bool _serverHasReloadableChanges(ServerConfig old, ServerConfig newVal) {
    // Compare fields other than port, host, dataDir.
    return old.name != newVal.name ||
        old.baseUrl != newVal.baseUrl ||
        old.claudeExecutable != newVal.claudeExecutable ||
        old.staticDir != newVal.staticDir ||
        old.templatesDir != newVal.templatesDir ||
        old.devMode != newVal.devMode ||
        old.maxParallelTurns != newVal.maxParallelTurns;
  }
}
