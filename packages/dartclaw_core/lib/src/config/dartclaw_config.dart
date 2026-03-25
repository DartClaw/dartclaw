import 'dart:collection';
import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../agents/agent_definition.dart';
import '../container/container_config.dart';
import '../scoping/channel_config.dart';
import '../scoping/channel_config_provider.dart';
import '../scoping/session_scope_config.dart';
import '../utils/path_utils.dart';
import 'agent_config.dart';
import 'auth_config.dart';
import 'context_config.dart';
import 'credentials_config.dart';
import 'gateway_config.dart';
import 'logging_config.dart';
import 'memory_config.dart';
import 'scheduled_task_definition.dart';
import 'scheduling_config.dart';
import 'search_config.dart';
import 'security_config.dart';
import 'server_config.dart';
import 'session_config.dart';
import 'features_config.dart';
import 'governance_config.dart';
import 'project_config.dart';
import 'providers_config.dart';
import 'session_maintenance_config.dart';
import 'task_config.dart';
import 'usage_config.dart';
import 'workspace_config.dart';

/// Immutable configuration for DartClaw runtime.
class DartclawConfig {
  static final Expando<Map<ChannelType, Object>> _lazyChannelConfigCache = Expando('channelConfigCache');
  static final Expando<List<String>> _lazyChannelConfigWarnings = Expando('channelConfigWarnings');
  static final Map<ChannelType, Object Function(Map<String, dynamic>, List<String>)> _channelConfigParsers = {};
  static final Map<String, Object Function(Map<String, dynamic>, List<String>)> _extensionParsers = {};

  // --- Composed section fields ---
  final ServerConfig server;
  final AgentConfig agent;
  final AuthConfig auth;
  final GatewayConfig gateway;
  final SessionConfig sessions;
  final ContextConfig context;
  final SecurityConfig security;
  final MemoryConfig memory;
  final SearchConfig search;
  final ProvidersConfig providers;
  final CredentialsConfig credentials;
  final TaskConfig tasks;
  final SchedulingConfig scheduling;
  final WorkspaceConfig workspace;
  final LoggingConfig logging;
  final UsageConfig usage;
  final ContainerConfig container;
  final ChannelConfig channels;
  final GovernanceConfig governance;
  final FeaturesConfig features;
  final ProjectConfig projects;

  /// Extension sections registered by private deployers via [registerExtensionParser].
  /// Unknown YAML keys with registered parsers produce typed entries here.
  /// Unknown YAML keys without registered parsers are stored as raw values
  /// (map, scalar, list, or null) for lossless forward-compatibility.
  final Map<String, Object?> extensions;

  /// Warnings collected during [load] and channel config parsing.
  /// Callers are responsible for surfacing these.
  final List<String> _warnings;

  List<String> get warnings => UnmodifiableListView(_warningSink());
  ChannelConfigProvider get channelConfigProvider => _ConfigChannelConfigProvider(this);

  // --- Derived path getters ---
  String get workspaceDir => p.join(server.dataDir, 'workspace');
  String get sessionsDir => p.join(server.dataDir, 'sessions');
  String get logsDir => p.join(server.dataDir, 'logs');
  String get searchDbPath => p.join(server.dataDir, 'search.db');
  String get tasksDbPath => p.join(server.dataDir, 'tasks.db');
  String get kvPath => p.join(server.dataDir, 'kv.json');
  String get projectsJsonPath => p.join(server.dataDir, 'projects.json');
  String get projectsClonesDir => p.join(server.dataDir, 'projects');

  const DartclawConfig({
    this.server = const ServerConfig.defaults(),
    this.agent = const AgentConfig.defaults(),
    this.auth = const AuthConfig.defaults(),
    this.gateway = const GatewayConfig.defaults(),
    this.sessions = const SessionConfig.defaults(),
    this.context = const ContextConfig.defaults(),
    this.security = const SecurityConfig.defaults(),
    this.memory = const MemoryConfig.defaults(),
    this.search = const SearchConfig.defaults(),
    this.providers = const ProvidersConfig.defaults(),
    this.credentials = const CredentialsConfig.defaults(),
    this.tasks = const TaskConfig.defaults(),
    this.scheduling = const SchedulingConfig.defaults(),
    this.workspace = const WorkspaceConfig.defaults(),
    this.logging = const LoggingConfig.defaults(),
    this.usage = const UsageConfig.defaults(),
    this.container = const ContainerConfig.disabled(),
    this.channels = const ChannelConfig.defaults(),
    this.governance = const GovernanceConfig.defaults(),
    this.features = const FeaturesConfig(),
    this.projects = const ProjectConfig.defaults(),
    this.extensions = const {},
    List<String> warnings = const [],
  }) : _warnings = warnings;

  /// All default values.
  const DartclawConfig.defaults() : this();

  // ---------------------------------------------------------------------------
  // Channel config
  // ---------------------------------------------------------------------------

  /// Registers a parser for a channel config type that lives outside core.
  ///
  /// Channel packages currently call this from top-level import side effects in
  /// their public libraries. Bootstrap code that bundles channels must import
  /// those packages and ensure registration before calling [DartclawConfig.load].
  static void registerChannelConfigParser(
    ChannelType channelType,
    Object Function(Map<String, dynamic> yaml, List<String> warns) parser,
  ) {
    if (channelType == ChannelType.web) {
      throw ArgumentError('No channel config is defined for ${channelType.name}.');
    }

    _channelConfigParsers[channelType] = parser;
  }

  // ---------------------------------------------------------------------------
  // Extension registration (P7 custom sections)
  // ---------------------------------------------------------------------------

  /// Registers a parser for a custom top-level YAML section.
  ///
  /// Call this before [DartclawConfig.load] — typically in the private
  /// overlay's bootstrap, mirroring the [registerChannelConfigParser] pattern.
  ///
  /// Throws [ArgumentError] if [name] conflicts with a built-in config key.
  static void registerExtensionParser(
    String name,
    Object Function(Map<String, dynamic> yaml, List<String> warns) parser,
  ) {
    if (_knownKeys.contains(name)) {
      throw ArgumentError('Cannot register extension parser for built-in config key: "$name"');
    }
    _extensionParsers[name] = parser;
  }

  /// Removes all registered extension parsers.
  ///
  /// Only for use in tests — call in [setUp]/[tearDown] to avoid cross-test
  /// parser leakage.
  @visibleForTesting
  static void clearExtensionParsers() => _extensionParsers.clear();

  /// Returns the parsed extension section of type [T] registered under [name].
  ///
  /// Throws [StateError] if no extension is present for [name].
  /// Throws [ArgumentError] if the stored value is not assignable to [T].
  T extension<T>(String name) {
    if (!extensions.containsKey(name)) {
      throw StateError('No extension registered for "$name".');
    }
    final ext = extensions[name];
    if (ext is T) return ext;
    throw ArgumentError('Extension "$name" is ${ext.runtimeType}, not assignable to $T.');
  }

  T getChannelConfig<T>(ChannelType channelType) {
    final cachedConfig = _channelConfigFor(channelType);
    if (cachedConfig is! T) {
      throw ArgumentError(
        'Channel ${channelType.name} expects ${cachedConfig.runtimeType}, which is not assignable to $T.',
      );
    }
    return cachedConfig as T;
  }

  // ---------------------------------------------------------------------------
  // load() factory
  // ---------------------------------------------------------------------------

  /// Load config with resolution: CLI overrides > YAML file > defaults.
  ///
  /// [configPath] — explicit config file path (e.g. from `--config` flag).
  ///   Takes precedence over `DARTCLAW_CONFIG` env var and CWD discovery.
  /// [cliOverrides] — key/value pairs from CLI flags (snake_case keys).
  /// [env] — environment variables (defaults to `Platform.environment`).
  /// [fileReader] — returns file contents or null; injectable for tests.
  factory DartclawConfig.load({
    String? configPath,
    Map<String, String>? cliOverrides,
    Map<String, String>? env,
    String? Function(String path)? fileReader,
  }) {
    final environment = env ?? Platform.environment;
    final reader = fileReader ?? _defaultFileReader;
    final cli = cliOverrides ?? {};
    final warns = <String>[];

    // Find & read config file
    final yaml = _loadYaml(environment, reader, warns, configPath: configPath);

    // Parse each section using section defaults
    final server = _parseTopLevel(yaml, cli, environment, const ServerConfig.defaults(), warns);
    final logging = _parseLogging(yaml, cli, environment, const LoggingConfig.defaults(), warns);
    final agent = _parseAgent(yaml, const AgentConfig.defaults(), warns);
    final auth = _parseAuth(yaml, const AuthConfig.defaults(), warns);
    final gateway = _parseGateway(yaml, environment, const GatewayConfig.defaults(), warns);
    final sessions = _parseSessions(yaml, const SessionConfig.defaults(), warns);
    final context = _parseContext(yaml, const ContextConfig.defaults(), warns);
    final workspace = _parseWorkspace(yaml, const WorkspaceConfig.defaults(), warns);
    final scheduling = _parseScheduling(yaml, const SchedulingConfig.defaults(), warns);
    final search = _parseSearch(yaml, environment, const SearchConfig.defaults(), warns);
    final providers = _parseProviders(yaml, environment, const ProvidersConfig.defaults(), warns);
    final credentials = _parseCredentials(yaml, environment, const CredentialsConfig.defaults(), warns);
    final security = _parseSecurity(yaml, const SecurityConfig.defaults(), warns);
    final usage = _parseUsage(yaml, const UsageConfig.defaults(), warns);
    final memory = _parseMemory(yaml, cli, const MemoryConfig.defaults(), warns);
    final container = _parseContainer(yaml, warns);
    final channels = _parseChannels(yaml, warns);
    final tasks = _parseTasks(yaml, const TaskConfig.defaults(), warns);
    final governance = _parseGovernance(yaml, const GovernanceConfig.defaults(), warns);
    final features = _parseFeatures(yaml);
    final projects = parseProjectConfig(_sectionMap('projects', yaml, warns), warns);

    // Parse extension sections — unknown YAML keys passed to registered parsers
    // or stored as raw values for lossless forward-compatibility.
    final extensions = <String, Object?>{};
    for (final key in yaml.keys) {
      if (_knownKeys.contains(key)) continue;
      final rawValue = yaml[key];
      final parser = _extensionParsers[key];
      if (parser != null) {
        // null means "empty section" in YAML — pass {} to parser (matches
        // built-in section convention where null → use defaults).
        if (rawValue is Map || rawValue == null) {
          final rawMap = rawValue is Map ? Map<String, dynamic>.from(rawValue) : <String, dynamic>{};
          try {
            extensions[key] = parser(rawMap, warns);
          } catch (e) {
            warns.add('Error parsing extension "$key": $e — storing as raw data');
            extensions[key] = rawMap;
          }
        } else {
          // Scalar or list with a registered parser — warn and preserve raw.
          warns.add(
            'Extension "$key" expected a map but got '
            '${rawValue.runtimeType} — storing raw value',
          );
          extensions[key] = rawValue;
        }
      } else {
        // No parser — preserve the raw value verbatim (map, scalar, list, or null).
        extensions[key] = rawValue is Map ? Map<String, dynamic>.from(rawValue) : rawValue;
      }
    }

    final config = DartclawConfig(
      server: server,
      agent: agent,
      auth: auth,
      gateway: gateway,
      sessions: sessions,
      context: context,
      security: security,
      memory: memory,
      search: search,
      providers: providers,
      credentials: credentials,
      tasks: tasks,
      scheduling: scheduling,
      workspace: workspace,
      logging: logging,
      usage: usage,
      container: container,
      channels: channels,
      governance: governance,
      features: features,
      projects: projects,
      extensions: extensions,
      warnings: warns,
    );

    config._primeChannelConfigs();
    return config;
  }

  void _primeChannelConfigs() {
    for (final channelType in _channelConfigParsers.keys) {
      _channelConfigFor(channelType);
    }
  }

  Object _channelConfigFor(ChannelType channelType) {
    if (channelType == ChannelType.web) {
      throw ArgumentError('No channel config is defined for ${channelType.name}.');
    }

    final cache = _lazyChannelConfigCache[this] ??= <ChannelType, Object>{};
    return cache.putIfAbsent(channelType, () => _parseChannelConfig(channelType));
  }

  Object _parseChannelConfig(ChannelType channelType) {
    final parser = _channelConfigParsers[channelType];
    if (parser == null) {
      // Missing registration is still a bootstrap error. Hosts are expected to
      // import the channel package so its top-level self-registration runs
      // before [DartclawConfig.load] primes channel configs.
      throw StateError(
        'No config parser registered for ${channelType.name}. '
        'Import that channel package before requesting its config.',
      );
    }

    final warns = _warningSink();
    final configKey = switch (channelType) {
      ChannelType.googlechat => 'google_chat',
      ChannelType.signal => 'signal',
      ChannelType.whatsapp => 'whatsapp',
      ChannelType.web => throw ArgumentError('No channel config is defined for ${channelType.name}.'),
    };

    return parser(channels.channelConfigs[configKey] ?? const <String, dynamic>{}, warns);
  }

  List<String> _warningSink() => _lazyChannelConfigWarnings[this] ??= List<String>.of(_warnings);

  // ---------------------------------------------------------------------------
  // Section parse methods — each returns a section type or named record
  // ---------------------------------------------------------------------------

  static ServerConfig _parseTopLevel(
    Map<String, dynamic> yaml,
    Map<String, String> cli,
    Map<String, String> env,
    ServerConfig defaults,
    List<String> warns,
  ) {
    final port = _parseInt('port', cli['port'], yaml['port'], defaults.port, warns);
    final host = _parseString('host', cli['host'], yaml['host'], defaults.host, env, warns);
    final name = _parseString('name', cli['name'], yaml['name'], defaults.name, env, warns);
    final workerTimeout = _parseInt(
      'worker_timeout',
      cli['worker_timeout'],
      yaml['worker_timeout'],
      defaults.workerTimeout,
      warns,
    );

    // dataDir: CLI > YAML > default, with ~ expansion
    final rawDataDir = cli['data_dir'] ?? _yamlString('data_dir', yaml['data_dir'], defaults.dataDir, env, warns);
    final dataDir = expandHome(rawDataDir, env: env);

    // claudeExecutable, staticDir, templatesDir: CLI only (not from YAML), with ~ expansion
    final claudeExecutable = expandHome(cli['claude_executable'] ?? defaults.claudeExecutable, env: env);
    final staticDir = expandHome(cli['static_dir'] ?? defaults.staticDir, env: env);
    final templatesDir = expandHome(cli['templates_dir'] ?? defaults.templatesDir, env: env);

    // dev_mode: enables template hot-reload, etc.
    final devMode = yaml['dev_mode'] == true || cli['dev_mode'] == 'true';

    final maxParallelTurns = _parseInt(
      'concurrency.max_parallel_turns',
      null,
      (yaml['concurrency'] is Map) ? (yaml['concurrency'] as Map)['max_parallel_turns'] : null,
      defaults.maxParallelTurns,
      warns,
    );

    return ServerConfig(
      port: port,
      host: host,
      name: name,
      dataDir: dataDir,
      workerTimeout: workerTimeout,
      claudeExecutable: claudeExecutable,
      staticDir: staticDir,
      templatesDir: templatesDir,
      devMode: devMode,
      maxParallelTurns: maxParallelTurns,
    );
  }

  static LoggingConfig _parseLogging(
    Map<String, dynamic> yaml,
    Map<String, String> cli,
    Map<String, String> env,
    LoggingConfig defaults,
    List<String> warns,
  ) {
    var format = cli['log_format'] ?? defaults.format;
    String? file = cli['log_file'] != null ? expandHome(cli['log_file']!, env: env) : null;
    var level = cli['log_level'] ?? defaults.level;
    var redactPatterns = defaults.redactPatterns;

    final loggingRaw = yaml['logging'];
    if (loggingRaw != null) {
      if (loggingRaw is Map) {
        final logMap = Map<String, dynamic>.from(loggingRaw);
        if (cli['log_format'] == null && logMap['format'] is String) {
          format = logMap['format'] as String;
        }
        if (cli['log_file'] == null && logMap['file'] is String) {
          file = expandHome(envSubstitute(logMap['file'] as String, env: env), env: env);
        }
        if (cli['log_level'] == null && logMap['level'] is String) {
          level = logMap['level'] as String;
        }
        final patternsRaw = logMap['redact_patterns'];
        if (patternsRaw is List) {
          redactPatterns = patternsRaw.whereType<String>().toList();
        }
      } else {
        warns.add('Invalid type for logging: "${loggingRaw.runtimeType}" — using defaults');
      }
    }

    return LoggingConfig(format: format, file: file, level: level, redactPatterns: redactPatterns);
  }

  static AgentConfig _parseAgent(Map<String, dynamic> yaml, AgentConfig defaults, List<String> warns) {
    var provider = defaults.provider;
    var disallowedTools = defaults.disallowedTools;
    int? maxTurns = defaults.maxTurns;
    String? model = defaults.model;
    String? effort = defaults.effort;

    final agentMap = _sectionMap('agent', yaml, warns);
    if (agentMap != null) {
      final disallowed = agentMap['disallowed_tools'];
      if (disallowed is List) {
        disallowedTools = disallowed.whereType<String>().toList();
      }
      final providerVal = agentMap['provider'];
      if (providerVal is String) {
        provider = providerVal;
      } else if (providerVal != null) {
        warns.add('Invalid type for agent.provider: "${providerVal.runtimeType}" — ignoring');
      }
      final mt = agentMap['max_turns'];
      if (mt is int) {
        maxTurns = mt;
      } else if (mt != null) {
        warns.add('Invalid type for agent.max_turns: "${mt.runtimeType}" — ignoring');
      }
      final modelVal = agentMap['model'];
      if (modelVal is String) {
        model = modelVal;
      } else if (modelVal != null) {
        warns.add('Invalid type for agent.model: "${modelVal.runtimeType}" — ignoring');
      }
      final effortVal = agentMap['effort'];
      if (effortVal is String) {
        effort = effortVal;
      } else if (effortVal != null) {
        warns.add('Invalid type for agent.effort: "${effortVal.runtimeType}" — ignoring');
      }
    }

    // Parse structured agent definitions from agent.agents
    final definitions = <AgentDefinition>[];
    final agentsVal = agentMap?['agents'];
    if (agentsVal is Map) {
      for (final entry in agentsVal.entries) {
        final id = entry.key;
        final value = entry.value;
        if (value is Map) {
          definitions.add(AgentDefinition.fromYaml(id as String, Map<String, dynamic>.from(value), warns));
        }
      }
    }

    return AgentConfig(
      provider: provider,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
      disallowedTools: disallowedTools,
      definitions: definitions,
    );
  }

  static AuthConfig _parseAuth(Map<String, dynamic> yaml, AuthConfig defaults, List<String> warns) {
    var cookieSecure = defaults.cookieSecure;
    var trustedProxies = defaults.trustedProxies;

    final authMap = _sectionMap('auth', yaml, warns);
    if (authMap != null) {
      final value = authMap['cookie_secure'];
      if (value is bool) {
        cookieSecure = value;
      } else if (value != null) {
        warns.add('Invalid type for auth.cookie_secure: "${value.runtimeType}" — using default');
      }

      final trustedProxyValue = authMap['trusted_proxies'];
      if (trustedProxyValue is List) {
        trustedProxies = trustedProxyValue.whereType<String>().toList(growable: false);
      } else if (trustedProxyValue != null) {
        warns.add('Invalid type for auth.trusted_proxies: "${trustedProxyValue.runtimeType}" — using default');
      }
    }

    return AuthConfig(cookieSecure: cookieSecure, trustedProxies: trustedProxies);
  }

  static GatewayConfig _parseGateway(
    Map<String, dynamic> yaml,
    Map<String, String> env,
    GatewayConfig defaults,
    List<String> warns,
  ) {
    var authMode = defaults.authMode;
    String? token = defaults.token;
    var hsts = defaults.hsts;

    final gMap = _sectionMap('gateway', yaml, warns);
    if (gMap != null) {
      final mode = gMap['auth_mode'];
      if (mode is String) {
        if (mode == 'token' || mode == 'none') {
          authMode = mode;
        } else {
          warns.add('Invalid gateway.auth_mode: "$mode" — using default');
        }
      } else if (mode != null) {
        warns.add('Invalid type for gateway.auth_mode: "${mode.runtimeType}" — using default');
      }
      final tokenVal = gMap['token'];
      if (tokenVal is String && tokenVal.isNotEmpty) {
        token = envSubstitute(tokenVal, env: env);
      } else if (tokenVal != null && tokenVal is! String) {
        warns.add('Invalid type for gateway.token: "${tokenVal.runtimeType}" — ignoring');
      }
      final hstsVal = gMap['hsts'];
      if (hstsVal is bool) {
        hsts = hstsVal;
      } else if (hstsVal != null) {
        warns.add('Invalid type for gateway.hsts: "${hstsVal.runtimeType}" — using default');
      }
    }

    return GatewayConfig(authMode: authMode, token: token, hsts: hsts);
  }

  static SessionConfig _parseSessions(Map<String, dynamic> yaml, SessionConfig defaults, List<String> warns) {
    var resetHour = defaults.resetHour;
    var idleTimeoutMinutes = defaults.idleTimeoutMinutes;
    var scopeConfig = defaults.scopeConfig;
    var maintenanceConfig = defaults.maintenanceConfig;

    final sessionsMap = _sectionMap('sessions', yaml, warns);
    if (sessionsMap != null) {
      resetHour = _parseInt('sessions.reset_hour', null, sessionsMap['reset_hour'], defaults.resetHour, warns);
      idleTimeoutMinutes = _parseInt(
        'sessions.idle_timeout_minutes',
        null,
        sessionsMap['idle_timeout_minutes'],
        defaults.idleTimeoutMinutes,
        warns,
      );
      scopeConfig = _parseSessionScope(sessionsMap, defaults.scopeConfig, warns);
      maintenanceConfig = _parseSessionMaintenance(sessionsMap, defaults.maintenanceConfig, warns);
    }

    return SessionConfig(
      resetHour: resetHour,
      idleTimeoutMinutes: idleTimeoutMinutes,
      scopeConfig: scopeConfig,
      maintenanceConfig: maintenanceConfig,
    );
  }

  static SessionScopeConfig _parseSessionScope(
    Map<dynamic, dynamic> sessionsRaw,
    SessionScopeConfig defaultScope,
    List<String> warns,
  ) {
    // Parse global dm_scope
    var dmScope = defaultScope.dmScope;
    final dmScopeRaw = sessionsRaw['dm_scope'];
    if (dmScopeRaw is String) {
      final parsed = DmScope.fromYaml(dmScopeRaw);
      if (parsed != null) {
        dmScope = parsed;
      } else {
        warns.add('Invalid value for sessions.dm_scope: "$dmScopeRaw" — using default');
      }
    } else if (dmScopeRaw != null) {
      warns.add('Invalid type for sessions.dm_scope: "${dmScopeRaw.runtimeType}" — using default');
    }

    // Parse global group_scope
    var groupScope = defaultScope.groupScope;
    final groupScopeRaw = sessionsRaw['group_scope'];
    if (groupScopeRaw is String) {
      final parsed = GroupScope.fromYaml(groupScopeRaw);
      if (parsed != null) {
        groupScope = parsed;
      } else {
        warns.add('Invalid value for sessions.group_scope: "$groupScopeRaw" — using default');
      }
    } else if (groupScopeRaw != null) {
      warns.add('Invalid type for sessions.group_scope: "${groupScopeRaw.runtimeType}" — using default');
    }

    // Parse per-channel overrides
    final channelOverrides = <String, ChannelScopeConfig>{};
    final channelsRaw = sessionsRaw['channels'];
    if (channelsRaw is Map) {
      for (final entry in channelsRaw.entries) {
        final channelName = entry.key;
        if (channelName is! String) continue;
        final channelMap = entry.value;
        if (channelMap is! Map) {
          warns.add('Invalid type for sessions.channels.$channelName: "${channelMap.runtimeType}" — skipping');
          continue;
        }

        DmScope? chDmScope;
        final chDmRaw = channelMap['dm_scope'];
        if (chDmRaw is String) {
          chDmScope = DmScope.fromYaml(chDmRaw);
          if (chDmScope == null) {
            warns.add('Invalid value for sessions.channels.$channelName.dm_scope: "$chDmRaw" — ignoring');
          }
        }

        GroupScope? chGroupScope;
        final chGroupRaw = channelMap['group_scope'];
        if (chGroupRaw is String) {
          chGroupScope = GroupScope.fromYaml(chGroupRaw);
          if (chGroupScope == null) {
            warns.add('Invalid value for sessions.channels.$channelName.group_scope: "$chGroupRaw" — ignoring');
          }
        }

        if (chDmScope != null || chGroupScope != null) {
          channelOverrides[channelName] = ChannelScopeConfig(dmScope: chDmScope, groupScope: chGroupScope);
        }
      }
    } else if (channelsRaw != null) {
      warns.add('Invalid type for sessions.channels: "${channelsRaw.runtimeType}" — skipping overrides');
    }

    return SessionScopeConfig(dmScope: dmScope, groupScope: groupScope, channels: channelOverrides);
  }

  static SessionMaintenanceConfig _parseSessionMaintenance(
    Map<dynamic, dynamic> sessionsRaw,
    SessionMaintenanceConfig defaultMaint,
    List<String> warns,
  ) {
    final maintRaw = sessionsRaw['maintenance'];
    if (maintRaw is! Map) {
      if (maintRaw != null) {
        warns.add('Invalid type for sessions.maintenance: "${maintRaw.runtimeType}" — using defaults');
      }
      return defaultMaint;
    }

    // Parse mode
    var mode = defaultMaint.mode;
    final modeRaw = maintRaw['mode'];
    if (modeRaw is String) {
      final parsed = MaintenanceMode.fromYaml(modeRaw);
      if (parsed != null) {
        mode = parsed;
      } else {
        warns.add('Invalid value for sessions.maintenance.mode: "$modeRaw" — using default');
      }
    } else if (modeRaw != null) {
      warns.add('Invalid type for sessions.maintenance.mode: "${modeRaw.runtimeType}" — using default');
    }

    final pruneAfterDays = _parseInt(
      'sessions.maintenance.prune_after_days',
      null,
      maintRaw['prune_after_days'],
      defaultMaint.pruneAfterDays,
      warns,
    );
    final maxSessions = _parseInt(
      'sessions.maintenance.max_sessions',
      null,
      maintRaw['max_sessions'],
      defaultMaint.maxSessions,
      warns,
    );
    final maxDiskMb = _parseInt(
      'sessions.maintenance.max_disk_mb',
      null,
      maintRaw['max_disk_mb'],
      defaultMaint.maxDiskMb,
      warns,
    );
    final cronRetentionHours = _parseInt(
      'sessions.maintenance.cron_retention_hours',
      null,
      maintRaw['cron_retention_hours'],
      defaultMaint.cronRetentionHours,
      warns,
    );

    // Parse schedule
    var schedule = defaultMaint.schedule;
    final schedRaw = maintRaw['schedule'];
    if (schedRaw is String && schedRaw.isNotEmpty) {
      schedule = schedRaw;
    } else if (schedRaw != null && schedRaw is! String) {
      warns.add('Invalid type for sessions.maintenance.schedule: "${schedRaw.runtimeType}" — using default');
    }

    return SessionMaintenanceConfig(
      mode: mode,
      pruneAfterDays: pruneAfterDays,
      maxSessions: maxSessions,
      maxDiskMb: maxDiskMb,
      cronRetentionHours: cronRetentionHours,
      schedule: schedule,
    );
  }

  static ContextConfig _parseContext(Map<String, dynamic> yaml, ContextConfig defaults, List<String> warns) {
    var reserveTokens = defaults.reserveTokens;
    var maxResultBytes = defaults.maxResultBytes;
    var warningThreshold = defaults.warningThreshold;
    var explorationSummaryThreshold = defaults.explorationSummaryThreshold;
    String? compactInstructions = defaults.compactInstructions;

    final contextMap = _sectionMap('context', yaml, warns);
    if (contextMap != null) {
      reserveTokens = _parseInt(
        'context.reserve_tokens',
        null,
        contextMap['reserve_tokens'],
        defaults.reserveTokens,
        warns,
      );
      maxResultBytes = _parseInt(
        'context.max_result_bytes',
        null,
        contextMap['max_result_bytes'],
        defaults.maxResultBytes,
        warns,
      );
      warningThreshold = _parseInt(
        'context.warning_threshold',
        null,
        contextMap['warning_threshold'],
        defaults.warningThreshold,
        warns,
      ).clamp(50, 99);
      explorationSummaryThreshold = _parseInt(
        'context.exploration_summary_threshold',
        null,
        contextMap['exploration_summary_threshold'],
        defaults.explorationSummaryThreshold,
        warns,
      ).clamp(1000, 1000000);
      final ciRaw = contextMap['compact_instructions'];
      if (ciRaw is String && ciRaw.trim().isNotEmpty) {
        compactInstructions = ciRaw;
      } else if (ciRaw != null && ciRaw is! String) {
        warns.add(
          'Invalid type for context.compact_instructions: '
          '"${ciRaw.runtimeType}" — using default',
        );
      }
    }

    return ContextConfig(
      reserveTokens: reserveTokens,
      maxResultBytes: maxResultBytes,
      warningThreshold: warningThreshold,
      explorationSummaryThreshold: explorationSummaryThreshold,
      compactInstructions: compactInstructions,
    );
  }

  static WorkspaceConfig _parseWorkspace(Map<String, dynamic> yaml, WorkspaceConfig defaults, List<String> warns) {
    var gitSyncEnabled = defaults.gitSyncEnabled;
    var gitSyncPushEnabled = defaults.gitSyncPushEnabled;

    final workspaceMap = _sectionMap('workspace', yaml, warns);
    if (workspaceMap != null) {
      final gsRaw = workspaceMap['git_sync'];
      if (gsRaw is Map) {
        final en = gsRaw['enabled'];
        if (en is bool) gitSyncEnabled = en;
        final pe = gsRaw['push_enabled'];
        if (pe is bool) gitSyncPushEnabled = pe;
      }
    }

    return WorkspaceConfig(gitSyncEnabled: gitSyncEnabled, gitSyncPushEnabled: gitSyncPushEnabled);
  }

  static SchedulingConfig _parseScheduling(Map<String, dynamic> yaml, SchedulingConfig defaults, List<String> warns) {
    var jobs = <Map<String, dynamic>>[];
    var heartbeatEnabled = defaults.heartbeatEnabled;
    var heartbeatIntervalMinutes = defaults.heartbeatIntervalMinutes;

    final schedulingMap = _sectionMap('scheduling', yaml, warns);
    if (schedulingMap != null) {
      final jobsRaw = schedulingMap['jobs'];
      if (jobsRaw is List) {
        for (final entry in jobsRaw) {
          if (entry is Map) {
            jobs.add(Map<String, dynamic>.from(entry));
          } else {
            warns.add('Invalid scheduling job entry: "${entry.runtimeType}" — skipping');
          }
        }
      } else if (jobsRaw != null) {
        warns.add('Invalid type for scheduling.jobs: "${jobsRaw.runtimeType}" — expected list');
      }

      // Heartbeat config (under scheduling.heartbeat)
      final hbRaw = schedulingMap['heartbeat'];
      if (hbRaw is Map) {
        final en = hbRaw['enabled'];
        if (en is bool) heartbeatEnabled = en;
        heartbeatIntervalMinutes = _parseInt(
          'scheduling.heartbeat.interval_minutes',
          null,
          hbRaw['interval_minutes'],
          defaults.heartbeatIntervalMinutes,
          warns,
        );
      }
    }

    // Extract ScheduledTaskDefinition objects from type:task entries in jobs
    final taskDefs = <ScheduledTaskDefinition>[];
    for (final jobMap in jobs) {
      final typeStr = jobMap['type'] as String?;
      if (typeStr == 'task') {
        final taskRaw = jobMap['task'];
        if (taskRaw is! Map) {
          warns.add(
            'Scheduling job "${jobMap['id'] ?? jobMap['name']}" (type: task) missing "task" section — skipping',
          );
          continue;
        }
        final id = (jobMap['id'] ?? jobMap['name']) as String? ?? '';

        // Extract cron expression from schedule (may be bare string or map)
        final scheduleRaw = jobMap['schedule'];
        final String cronExpr;
        if (scheduleRaw is String) {
          cronExpr = scheduleRaw.trim();
        } else if (scheduleRaw is Map) {
          cronExpr = (scheduleRaw['expression'] as String? ?? '').trim();
        } else {
          warns.add('Scheduling job "$id" (type: task) missing schedule — skipping');
          continue;
        }

        final syntheticYaml = <String, dynamic>{
          'id': id,
          'schedule': cronExpr,
          'enabled': jobMap['enabled'] ?? true,
          'task': taskRaw,
        };
        final def = ScheduledTaskDefinition.fromYaml(syntheticYaml, warns);
        if (def != null) taskDefs.add(def);
      }
    }

    // Deprecated alias: automation.scheduled_tasks
    final automationResult = _parseAutomation(yaml, warns);
    if (automationResult.taskDefs.isNotEmpty) {
      taskDefs.addAll(automationResult.taskDefs);
      jobs.addAll(automationResult.convertedJobs);
    }

    return SchedulingConfig(
      jobs: jobs,
      taskDefinitions: taskDefs,
      heartbeatEnabled: heartbeatEnabled,
      heartbeatIntervalMinutes: heartbeatIntervalMinutes,
    );
  }

  static SearchConfig _parseSearch(
    Map<String, dynamic> yaml,
    Map<String, String> env,
    SearchConfig defaults,
    List<String> warns,
  ) {
    final providers = <String, SearchProviderEntry>{};
    var backend = defaults.backend;
    var qmdHost = defaults.qmdHost;
    var qmdPort = defaults.qmdPort;
    var defaultDepth = defaults.defaultDepth;

    final searchMap = _sectionMap('search', yaml, warns);
    if (searchMap != null) {
      final backendVal = searchMap['backend'];
      if (backendVal is String && (backendVal == 'fts5' || backendVal == 'qmd')) {
        backend = backendVal;
      } else if (backendVal != null) {
        warns.add('Invalid search.backend: "$backendVal" — using default');
      }
      final qmdRaw = searchMap['qmd'];
      if (qmdRaw is Map) {
        final h = qmdRaw['host'];
        if (h is String) qmdHost = h;
        qmdPort = _parseInt('search.qmd.port', null, qmdRaw['port'], defaults.qmdPort, warns);
      }
      final depth = searchMap['default_depth'];
      if (depth is String) defaultDepth = depth;

      // Search providers (brave, tavily, etc.)
      final providersRaw = searchMap['providers'];
      if (providersRaw is Map) {
        for (final entry in providersRaw.entries) {
          final name = entry.key.toString();
          final value = entry.value;
          if (value is! Map) {
            warns.add('Invalid type for search.providers.$name: "${value.runtimeType}" — skipping');
            continue;
          }
          final enabled = value['enabled'];
          if (enabled is! bool) {
            warns.add('search.providers.$name missing or invalid "enabled" — skipping');
            continue;
          }
          final rawKey = value['api_key'];
          if (rawKey == null || rawKey is! String || rawKey.isEmpty) {
            warns.add('search.providers.$name missing "api_key" — skipping');
            continue;
          }
          final apiKey = envSubstitute(rawKey, env: env);
          providers[name] = SearchProviderEntry(enabled: enabled, apiKey: apiKey);
        }
      } else if (providersRaw != null) {
        warns.add('Invalid type for search.providers: "${providersRaw.runtimeType}" — skipping');
      }
    }

    return SearchConfig(
      backend: backend,
      qmdHost: qmdHost,
      qmdPort: qmdPort,
      defaultDepth: defaultDepth,
      providers: providers,
    );
  }

  static ProvidersConfig _parseProviders(
    Map<String, dynamic> yaml,
    Map<String, String> env,
    ProvidersConfig defaults,
    List<String> warns,
  ) {
    final providersRaw = yaml['providers'];
    if (providersRaw == null) {
      return defaults;
    }
    if (providersRaw is! Map) {
      warns.add('Invalid type for providers: "${providersRaw.runtimeType}" — using defaults');
      return defaults;
    }

    final entries = <String, ProviderEntry>{};
    for (final entry in providersRaw.entries) {
      final providerId = entry.key.toString();
      final value = entry.value;
      if (value is! Map) {
        warns.add('Invalid type for providers.$providerId: "${value.runtimeType}" — skipping');
        continue;
      }

      final providerMap = Map<String, dynamic>.from(value);
      final executableRaw = providerMap['executable'];
      if (executableRaw is! String || executableRaw.trim().isEmpty) {
        warns.add('providers.$providerId missing "executable" — skipping');
        continue;
      }

      var poolSize = 0;
      final poolSizeRaw = providerMap['pool_size'];
      if (poolSizeRaw is int) {
        poolSize = poolSizeRaw;
      } else if (poolSizeRaw != null) {
        warns.add('Invalid type for providers.$providerId.pool_size: "${poolSizeRaw.runtimeType}" — using default');
      }

      final options = Map<String, dynamic>.from(providerMap)
        ..remove('executable')
        ..remove('pool_size');

      entries[providerId] = ProviderEntry(
        executable: expandHome(executableRaw.trim(), env: env),
        poolSize: poolSize,
        options: options,
      );
    }

    return ProvidersConfig(entries: entries);
  }

  static CredentialsConfig _parseCredentials(
    Map<String, dynamic> yaml,
    Map<String, String> env,
    CredentialsConfig defaults,
    List<String> warns,
  ) {
    final credentialsRaw = yaml['credentials'];
    if (credentialsRaw == null) {
      return defaults;
    }
    if (credentialsRaw is! Map) {
      warns.add('Invalid type for credentials: "${credentialsRaw.runtimeType}" — using defaults');
      return defaults;
    }

    final entries = <String, CredentialEntry>{};
    for (final entry in credentialsRaw.entries) {
      final credentialName = entry.key.toString();
      final value = entry.value;
      if (value is! Map) {
        warns.add('Invalid type for credentials.$credentialName: "${value.runtimeType}" — skipping');
        continue;
      }

      final credentialMap = Map<String, dynamic>.from(value);
      final apiKeyRaw = credentialMap['api_key'];
      if (apiKeyRaw is! String) {
        warns.add('credentials.$credentialName missing "api_key" — skipping');
        continue;
      }

      entries[credentialName] = CredentialEntry(apiKey: envSubstitute(apiKeyRaw, env: env));
    }

    return CredentialsConfig(entries: entries);
  }

  static SecurityConfig _parseSecurity(Map<String, dynamic> yaml, SecurityConfig defaults, List<String> warns) {
    // Guards
    final guardsRaw = yaml['guards'];
    final guardsYaml = guardsRaw is Map ? Map<String, dynamic>.from(guardsRaw) : <String, dynamic>{};
    GuardConfig guards;
    if (guardsRaw is Map) {
      try {
        guards = GuardConfig.fromYaml(guardsYaml, warns);
      } catch (e) {
        warns.add('Error parsing guards config: $e — using defaults');
        guards = const GuardConfig.defaults();
      }
    } else {
      if (guardsRaw != null) {
        warns.add('Invalid type for guards: "${guardsRaw.runtimeType}" — using defaults');
      }
      guards = const GuardConfig.defaults();
    }

    // Content guard (nested under guards.content)
    var contentGuardEnabled = defaults.contentGuardEnabled;
    var contentGuardClassifier = defaults.contentGuardClassifier;
    var contentGuardModel = defaults.contentGuardModel;
    var contentGuardMaxBytes = defaults.contentGuardMaxBytes;
    if (guardsRaw is Map) {
      final contentRaw = guardsRaw['content'];
      if (contentRaw is Map) {
        final en = contentRaw['enabled'];
        if (en is bool) contentGuardEnabled = en;
        final classifierVal = contentRaw['classifier'];
        if (classifierVal is String) {
          if (classifierVal == 'claude_binary' || classifierVal == 'anthropic_api') {
            contentGuardClassifier = classifierVal;
          } else {
            warns.add('Invalid guards.content.classifier: "$classifierVal" — using default');
          }
        }
        final modelVal = contentRaw['model'];
        if (modelVal is String) contentGuardModel = modelVal;
        contentGuardMaxBytes = _parseInt(
          'guards.content.max_bytes',
          null,
          contentRaw['max_bytes'],
          defaults.contentGuardMaxBytes,
          warns,
        );
      }
    }

    // Input sanitizer (nested under guards.input_sanitizer)
    var inputSanitizerEnabled = defaults.inputSanitizerEnabled;
    var inputSanitizerChannelsOnly = defaults.inputSanitizerChannelsOnly;
    if (guardsRaw is Map) {
      final isRaw = guardsRaw['input_sanitizer'];
      if (isRaw is Map) {
        final en = isRaw['enabled'];
        if (en is bool) inputSanitizerEnabled = en;
        final co = isRaw['channels_only'];
        if (co is bool) inputSanitizerChannelsOnly = co;
      }
    }

    // Guard audit (top-level guard_audit section)
    final guardAuditRaw = yaml['guard_audit'];
    if (guardAuditRaw is Map && guardAuditRaw.containsKey('max_entries')) {
      warns.add(
        'guard_audit.max_entries is deprecated and ignored — '
        'use guard_audit.max_retention_days for audit retention',
      );
    }
    final guardAuditMaxRetentionDays = _parseInt(
      'guard_audit.max_retention_days',
      null,
      (guardAuditRaw is Map) ? guardAuditRaw['max_retention_days'] : null,
      defaults.guardAuditMaxRetentionDays,
      warns,
    ).clamp(0, 365);

    return SecurityConfig(
      guards: guards,
      guardsYaml: guardsYaml,
      contentGuardEnabled: contentGuardEnabled,
      contentGuardClassifier: contentGuardClassifier,
      contentGuardModel: contentGuardModel,
      contentGuardMaxBytes: contentGuardMaxBytes,
      inputSanitizerEnabled: inputSanitizerEnabled,
      inputSanitizerChannelsOnly: inputSanitizerChannelsOnly,
      guardAuditMaxRetentionDays: guardAuditMaxRetentionDays,
    );
  }

  static UsageConfig _parseUsage(Map<String, dynamic> yaml, UsageConfig defaults, List<String> warns) {
    int? budgetWarningTokens = defaults.budgetWarningTokens;
    var maxFileSizeBytes = defaults.maxFileSizeBytes;

    final usageMap = _sectionMap('usage', yaml, warns);
    if (usageMap != null) {
      final bwt = usageMap['budget_warning_tokens'];
      if (bwt is int) {
        budgetWarningTokens = bwt;
      } else if (bwt != null) {
        warns.add('Invalid type for usage.budget_warning_tokens: "${bwt.runtimeType}" — ignoring');
      }
      maxFileSizeBytes = _parseInt(
        'usage.max_file_size_bytes',
        null,
        usageMap['max_file_size_bytes'],
        defaults.maxFileSizeBytes,
        warns,
      );
    }

    return UsageConfig(budgetWarningTokens: budgetWarningTokens, maxFileSizeBytes: maxFileSizeBytes);
  }

  static MemoryConfig _parseMemory(
    Map<String, dynamic> yaml,
    Map<String, String> cli,
    MemoryConfig defaults,
    List<String> warns,
  ) {
    var maxBytes = defaults.maxBytes;
    var pruningEnabled = defaults.pruningEnabled;
    var archiveAfterDays = defaults.archiveAfterDays;
    var pruningSchedule = defaults.pruningSchedule;

    final memoryMap = _sectionMap('memory', yaml, warns);
    final nestedMaxBytes = memoryMap?['max_bytes'];
    final pruningRaw = memoryMap?['pruning'];

    final legacyTopLevelMaxBytes = yaml['memory_max_bytes'];
    if (legacyTopLevelMaxBytes != null && nestedMaxBytes == null) {
      warns.add('Config key "memory_max_bytes" is deprecated; use "memory.max_bytes" instead');
    }

    if (nestedMaxBytes != null) {
      maxBytes = _parseInt('memory.max_bytes', cli['memory_max_bytes'], nestedMaxBytes, defaults.maxBytes, warns);
    } else {
      maxBytes = _parseInt(
        'memory_max_bytes',
        cli['memory_max_bytes'],
        legacyTopLevelMaxBytes,
        defaults.maxBytes,
        warns,
      );
    }

    if (pruningRaw is Map) {
      pruningEnabled = _parseBool(
        'memory.pruning.enabled',
        cli['memory_pruning_enabled'],
        pruningRaw['enabled'],
        pruningEnabled,
        warns,
      );
      archiveAfterDays = _parseInt(
        'memory.pruning.archive_after_days',
        cli['memory_pruning_archive_after_days'],
        pruningRaw['archive_after_days'],
        defaults.archiveAfterDays,
        warns,
      );
      final sched = pruningRaw['schedule'];
      if (cli['memory_pruning_schedule'] case final cliSchedule?) {
        pruningSchedule = cliSchedule;
      } else if (sched is String) {
        pruningSchedule = sched;
      }
    } else {
      pruningEnabled = _parseBool('memory.pruning.enabled', cli['memory_pruning_enabled'], null, pruningEnabled, warns);
      archiveAfterDays = _parseInt(
        'memory.pruning.archive_after_days',
        cli['memory_pruning_archive_after_days'],
        null,
        defaults.archiveAfterDays,
        warns,
      );
      if (cli['memory_pruning_schedule'] case final cliSchedule?) {
        pruningSchedule = cliSchedule;
      }
    }

    return MemoryConfig(
      maxBytes: maxBytes,
      pruningEnabled: pruningEnabled,
      archiveAfterDays: archiveAfterDays,
      pruningSchedule: pruningSchedule,
    );
  }

  static ContainerConfig _parseContainer(Map<String, dynamic> yaml, List<String> warns) {
    final containerRaw = yaml['container'];
    final config = containerRaw is Map
        ? ContainerConfig.fromYaml(Map<String, dynamic>.from(containerRaw), warns)
        : const ContainerConfig.disabled();
    if (containerRaw != null && containerRaw is! Map) {
      warns.add('Invalid type for container: "${containerRaw.runtimeType}" — using defaults');
    }
    return config;
  }

  static ChannelConfig _parseChannels(Map<String, dynamic> yaml, List<String> warns) {
    final channelsRaw = yaml['channels'];
    final config = channelsRaw is Map
        ? ChannelConfig.fromYaml(Map<String, dynamic>.from(channelsRaw), warns)
        : const ChannelConfig.defaults();
    if (channelsRaw != null && channelsRaw is! Map) {
      warns.add('Invalid type for channels: "${channelsRaw.runtimeType}" — using defaults');
    }
    return config;
  }

  static TaskConfig _parseTasks(Map<String, dynamic> yaml, TaskConfig defaults, List<String> warns) {
    var maxConcurrent = defaults.maxConcurrent;
    var artifactRetentionDays = defaults.artifactRetentionDays;
    var completionAction = defaults.completionAction;
    var worktreeBaseRef = defaults.worktreeBaseRef;
    var worktreeStaleTimeoutHours = defaults.worktreeStaleTimeoutHours;
    var worktreeMergeStrategy = defaults.worktreeMergeStrategy;

    final tasksMap = _sectionMap('tasks', yaml, warns);
    if (tasksMap != null) {
      maxConcurrent = _parseInt(
        'tasks.max_concurrent',
        null,
        tasksMap['max_concurrent'],
        defaults.maxConcurrent,
        warns,
      ).clamp(1, 10);
      artifactRetentionDays = _parseInt(
        'tasks.artifact_retention_days',
        null,
        tasksMap['artifact_retention_days'],
        defaults.artifactRetentionDays,
        warns,
      ).clamp(0, 3650);
      final completionActionRaw = tasksMap['completion_action'];
      if (completionActionRaw is String) {
        final trimmedCompletionAction = completionActionRaw.trim();
        if (trimmedCompletionAction == 'review' || trimmedCompletionAction == 'accept') {
          completionAction = trimmedCompletionAction;
        } else {
          warns.add(
            'Invalid value for tasks.completion_action: "$completionActionRaw" — using default '
            '"${defaults.completionAction}"',
          );
        }
      } else if (completionActionRaw != null) {
        warns.add('Invalid type for tasks.completion_action: "${completionActionRaw.runtimeType}" — using default');
      }

      final worktreeRaw = tasksMap['worktree'];
      if (worktreeRaw is Map) {
        final br = worktreeRaw['base_ref'];
        if (br is String && br.isNotEmpty) worktreeBaseRef = br;
        worktreeStaleTimeoutHours = _parseInt(
          'tasks.worktree.stale_timeout_hours',
          null,
          worktreeRaw['stale_timeout_hours'],
          defaults.worktreeStaleTimeoutHours,
          warns,
        ).clamp(1, 168);
        final ms = worktreeRaw['merge_strategy'];
        if (ms is String) {
          if (ms == 'squash' || ms == 'merge') {
            worktreeMergeStrategy = ms;
          } else {
            warns.add('Invalid value for tasks.worktree.merge_strategy: "$ms" — using default "squash"');
          }
        }
      } else if (worktreeRaw != null) {
        warns.add('Invalid type for tasks.worktree: "${worktreeRaw.runtimeType}" — using defaults');
      }
    }

    return TaskConfig(
      maxConcurrent: maxConcurrent,
      artifactRetentionDays: artifactRetentionDays,
      completionAction: completionAction,
      worktreeBaseRef: worktreeBaseRef,
      worktreeStaleTimeoutHours: worktreeStaleTimeoutHours,
      worktreeMergeStrategy: worktreeMergeStrategy,
    );
  }

  static GovernanceConfig _parseGovernance(Map<String, dynamic> yaml, GovernanceConfig defaults, List<String> warns) {
    final govMap = _sectionMap('governance', yaml, warns);
    if (govMap == null) return defaults;

    // admin_senders
    var adminSenders = defaults.adminSenders;
    final adminRaw = govMap['admin_senders'];
    if (adminRaw is List) {
      adminSenders = adminRaw.whereType<String>().toList();
    } else if (adminRaw != null) {
      warns.add('Invalid type for governance.admin_senders: "${adminRaw.runtimeType}" — using default');
    }

    // rate_limits
    var rateLimits = defaults.rateLimits;
    final rateLimitsRaw = govMap['rate_limits'];
    if (rateLimitsRaw is Map) {
      var perSender = rateLimits.perSender;
      var global = rateLimits.global;

      final perSenderRaw = rateLimitsRaw['per_sender'];
      if (perSenderRaw is Map) {
        final messages = _parseInt(
          'governance.rate_limits.per_sender.messages',
          null,
          perSenderRaw['messages'],
          perSender.messages,
          warns,
        );
        final windowMinutes = _parseInt(
          'governance.rate_limits.per_sender.window',
          null,
          _parseDurationMinutes(perSenderRaw['window']),
          perSender.windowMinutes,
          warns,
        );
        perSender = PerSenderRateLimitConfig(messages: messages, windowMinutes: windowMinutes);
      } else if (perSenderRaw != null) {
        warns.add('Invalid type for governance.rate_limits.per_sender: "${perSenderRaw.runtimeType}" — using defaults');
      }

      final globalRaw = rateLimitsRaw['global'];
      if (globalRaw is Map) {
        final turns = _parseInt('governance.rate_limits.global.turns', null, globalRaw['turns'], global.turns, warns);
        final windowMinutes = _parseInt(
          'governance.rate_limits.global.window',
          null,
          _parseDurationMinutes(globalRaw['window']),
          global.windowMinutes,
          warns,
        );
        global = GlobalRateLimitConfig(turns: turns, windowMinutes: windowMinutes);
      } else if (globalRaw != null) {
        warns.add('Invalid type for governance.rate_limits.global: "${globalRaw.runtimeType}" — using defaults');
      }

      rateLimits = RateLimitsConfig(perSender: perSender, global: global);
    } else if (rateLimitsRaw != null) {
      warns.add('Invalid type for governance.rate_limits: "${rateLimitsRaw.runtimeType}" — using defaults');
    }

    // budget
    var budget = defaults.budget;
    final budgetRaw = govMap['budget'];
    if (budgetRaw is Map) {
      final dailyTokens = _parseInt(
        'governance.budget.daily_tokens',
        null,
        budgetRaw['daily_tokens'],
        budget.dailyTokens,
        warns,
      );
      var action = budget.action;
      final actionRaw = budgetRaw['action'];
      if (actionRaw is String) {
        action = BudgetAction.fromYaml(actionRaw) ?? budget.action;
        if (BudgetAction.fromYaml(actionRaw) == null) {
          warns.add('Unknown governance.budget.action: "$actionRaw" — using default "${budget.action.name}"');
        }
      }
      var timezone = budget.timezone;
      final timezoneRaw = budgetRaw['timezone'];
      if (timezoneRaw is String && timezoneRaw.isNotEmpty) timezone = timezoneRaw;

      budget = BudgetConfig(dailyTokens: dailyTokens, action: action, timezone: timezone);
    } else if (budgetRaw != null) {
      warns.add('Invalid type for governance.budget: "${budgetRaw.runtimeType}" — using defaults');
    }

    // loop_detection
    var loopDetection = defaults.loopDetection;
    final loopRaw = govMap['loop_detection'];
    if (loopRaw is Map) {
      var enabled = loopDetection.enabled;
      final enabledRaw = loopRaw['enabled'];
      if (enabledRaw is bool) enabled = enabledRaw;

      final maxConsecutiveTurns = _parseInt(
        'governance.loop_detection.max_consecutive_turns',
        null,
        loopRaw['max_consecutive_turns'],
        loopDetection.maxConsecutiveTurns,
        warns,
      );
      final maxTokensPerMinute = _parseInt(
        'governance.loop_detection.max_tokens_per_minute',
        null,
        loopRaw['max_tokens_per_minute'],
        loopDetection.maxTokensPerMinute,
        warns,
      );
      final velocityWindowMinutes = _parseInt(
        'governance.loop_detection.velocity_window_minutes',
        null,
        loopRaw['velocity_window_minutes'],
        loopDetection.velocityWindowMinutes,
        warns,
      );
      final maxConsecutiveIdenticalToolCalls = _parseInt(
        'governance.loop_detection.max_consecutive_identical_tool_calls',
        null,
        loopRaw['max_consecutive_identical_tool_calls'],
        loopDetection.maxConsecutiveIdenticalToolCalls,
        warns,
      );

      var action = loopDetection.action;
      final actionRaw = loopRaw['action'];
      if (actionRaw is String) {
        action = LoopAction.fromYaml(actionRaw) ?? loopDetection.action;
        if (LoopAction.fromYaml(actionRaw) == null) {
          warns.add(
            'Unknown governance.loop_detection.action: "$actionRaw" — using default "${loopDetection.action.name}"',
          );
        }
      }

      loopDetection = LoopDetectionConfig(
        enabled: enabled,
        maxConsecutiveTurns: maxConsecutiveTurns,
        maxTokensPerMinute: maxTokensPerMinute,
        velocityWindowMinutes: velocityWindowMinutes,
        maxConsecutiveIdenticalToolCalls: maxConsecutiveIdenticalToolCalls,
        action: action,
      );
    } else if (loopRaw != null) {
      warns.add('Invalid type for governance.loop_detection: "${loopRaw.runtimeType}" — using defaults');
    }

    return GovernanceConfig(
      adminSenders: adminSenders,
      rateLimits: rateLimits,
      budget: budget,
      loopDetection: loopDetection,
    );
  }

  /// Parses a YAML duration value to integer minutes.
  ///
  /// Accepts: integer (minutes), or string with suffix: '30s' (→ 0), '5m' (→ 5),
  /// '1h' (→ 60), '2h' (→ 120). Returns null for unparseable values.
  static int? _parseDurationMinutes(Object? value) {
    if (value is int) return value;
    if (value is! String) return null;
    final s = value.trim().toLowerCase();
    if (s.endsWith('m')) {
      return int.tryParse(s.substring(0, s.length - 1));
    }
    if (s.endsWith('h')) {
      final hours = int.tryParse(s.substring(0, s.length - 1));
      return hours != null ? hours * 60 : null;
    }
    if (s.endsWith('s')) {
      // Seconds < 60 round to 0 minutes — accepted for forward compatibility.
      final secs = int.tryParse(s.substring(0, s.length - 1));
      return secs != null ? secs ~/ 60 : null;
    }
    return int.tryParse(s);
  }

  static ({List<Map<String, dynamic>> convertedJobs, List<ScheduledTaskDefinition> taskDefs}) _parseAutomation(
    Map<String, dynamic> yaml,
    List<String> warns,
  ) {
    const empty = (convertedJobs: <Map<String, dynamic>>[], taskDefs: <ScheduledTaskDefinition>[]);
    final automationRaw = yaml['automation'];
    if (automationRaw == null) return empty;
    if (automationRaw is! Map) {
      warns.add('Invalid type for automation: "${automationRaw.runtimeType}" — using defaults');
      return empty;
    }

    final tasksRaw = automationRaw['scheduled_tasks'];
    if (tasksRaw == null) return empty;
    if (tasksRaw is! List) {
      warns.add('Invalid type for automation.scheduled_tasks: "${tasksRaw.runtimeType}" — expected list');
      return empty;
    }

    warns.add('automation.scheduled_tasks is deprecated — move entries to scheduling.jobs with type: task');

    final taskDefs = <ScheduledTaskDefinition>[];
    for (final entry in tasksRaw) {
      if (entry is! Map) {
        warns.add('Invalid automation.scheduled_tasks entry: "${entry.runtimeType}" — skipping');
        continue;
      }
      final parsed = ScheduledTaskDefinition.fromYaml(Map<String, dynamic>.from(entry), warns);
      if (parsed != null) {
        taskDefs.add(parsed);
      }
    }

    // Produce unified raw job maps for the scheduling.jobs list.
    // toJson() already produces the right structure — just add the 'type' key.
    final convertedJobs = <Map<String, dynamic>>[
      for (final def in taskDefs) {'type': 'task', ...def.toJson()},
    ];

    return (convertedJobs: convertedJobs, taskDefs: taskDefs);
  }

  // --- Private helpers ---

  static String? _defaultFileReader(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// Reads a YAML section, validates it's a Map (or null), and warns on wrong type.
  /// Returns null if the key is absent, null-valued, or not a map.
  static Map<String, dynamic>? _sectionMap(String key, Map<String, dynamic> yaml, List<String> warns) {
    final raw = yaml[key];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw != null) {
      warns.add('Invalid type for $key: "${raw.runtimeType}" — using defaults');
    }
    return null;
  }

  static FeaturesConfig _parseFeatures(Map<String, dynamic> yaml) {
    final raw = yaml['features'];
    if (raw is Map) {
      return FeaturesConfig.fromYaml(Map<String, dynamic>.from(raw));
    }
    return const FeaturesConfig();
  }

  static const _knownKeys = {
    'port',
    'host',
    'name',
    'data_dir',
    'worker_timeout',
    'memory_max_bytes',
    'dev_mode',
    'guards',
    'logging',
    'agent',
    'auth',
    'gateway',
    'concurrency',
    'sessions',
    'scheduling',
    'context',
    'container',
    'channels',
    'providers',
    'credentials',
    'workspace',
    'search',
    'usage',
    'guard_audit',
    'memory',
    'tasks',
    'automation',
    'governance',
    'features',
    'projects',
  };

  static Map<String, dynamic> _loadYaml(
    Map<String, String> env,
    String? Function(String) reader,
    List<String> warns, {
    String? configPath,
  }) {
    // Config file search: --config > DARTCLAW_CONFIG env var > ./dartclaw.yaml > ~/.dartclaw/dartclaw.yaml
    String? content;

    if (configPath != null) {
      content = reader(expandHome(configPath, env: env));
      if (content == null) {
        warns.add('--config points to non-existent file: $configPath — using defaults');
        return {};
      }
    } else {
      final envPath = env['DARTCLAW_CONFIG'];
      if (envPath != null) {
        content = reader(expandHome(envPath, env: env));
        if (content == null) {
          warns.add('DARTCLAW_CONFIG points to non-existent file: $envPath — using defaults');
          return {};
        }
      } else {
        content = reader('dartclaw.yaml');
        content ??= reader(p.join(env['HOME'] ?? env['USERPROFILE'] ?? '.', '.dartclaw', 'dartclaw.yaml'));
      }
    }

    if (content == null) return {};

    Object? doc;
    try {
      doc = loadYaml(content);
    } on YamlException catch (e) {
      warns.add('YAML parse error — using defaults: $e');
      return {};
    }

    if (doc == null) return {};
    if (doc is! YamlMap && doc is! Map) {
      warns.add('YAML root is not a map — using defaults');
      return {};
    }

    final map = doc as Map;
    final result = <String, dynamic>{};

    for (final entry in map.entries) {
      final key = entry.key.toString();
      if (!_knownKeys.contains(key)) {
        // Unknown key — warn only if no extension parser is registered.
        // Preserve the raw value so load() can pass it to the parser (or store
        // it as raw data) after built-in sections have been parsed.
        if (!_extensionParsers.containsKey(key)) {
          warns.add('Unknown config key: $key');
        }
        result[key] = entry.value;
        continue;
      }
      if (entry.value == null) {
        warns.add('Config key "$key" is null — using default');
        continue;
      }
      result[key] = entry.value;
    }

    return result;
  }

  static int _parseInt(String key, String? cliValue, Object? yamlValue, int defaultValue, List<String> warns) {
    // CLI override
    if (cliValue != null) {
      final parsed = int.tryParse(cliValue);
      if (parsed != null) return parsed;
      warns.add('Invalid CLI value for $key: "$cliValue" — using default');
    }
    // YAML
    if (yamlValue != null) {
      if (yamlValue is int) return yamlValue;
      if (yamlValue is String) {
        final parsed = int.tryParse(yamlValue);
        if (parsed != null) return parsed;
      }
      warns.add('Invalid type for $key: "${yamlValue.runtimeType}" — using default');
    }
    return defaultValue;
  }

  static bool _parseBool(String key, String? cliValue, Object? yamlValue, bool defaultValue, List<String> warns) {
    if (cliValue != null) {
      if (cliValue == 'true') return true;
      if (cliValue == 'false') return false;
      warns.add('Invalid CLI value for $key: "$cliValue" — using default');
    }
    if (yamlValue is bool) return yamlValue;
    return defaultValue;
  }

  static String _parseString(
    String key,
    String? cliValue,
    Object? yamlValue,
    String defaultValue,
    Map<String, String> env,
    List<String> warns,
  ) {
    if (cliValue != null) return cliValue;
    return _yamlString(key, yamlValue, defaultValue, env, warns);
  }

  static String _yamlString(
    String key,
    Object? yamlValue,
    String defaultValue,
    Map<String, String> env,
    List<String> warns,
  ) {
    if (yamlValue == null) return defaultValue;
    if (yamlValue is! String) {
      warns.add('Invalid type for $key: "${yamlValue.runtimeType}" — using default');
      return defaultValue;
    }
    return envSubstitute(yamlValue, env: env);
  }
}

final class _ConfigChannelConfigProvider implements ChannelConfigProvider {
  final DartclawConfig _config;

  _ConfigChannelConfigProvider(this._config);

  @override
  T getChannelConfig<T>(ChannelType channelType) => _config.getChannelConfig<T>(channelType);
}
