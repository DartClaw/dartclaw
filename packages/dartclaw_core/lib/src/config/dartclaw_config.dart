import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../agents/agent_definition.dart';
import '../channel/channel_config.dart';
import '../container/container_config.dart';
import '../security/env_substitute.dart';
import '../security/guard_config.dart';
import '../utils/path_utils.dart';
import 'session_maintenance_config.dart';
import 'session_scope_config.dart';

/// Immutable configuration for DartClaw runtime.
class DartclawConfig {
  final int port;
  final String host;
  final String name;
  final String dataDir;
  final int workerTimeout;
  final String claudeExecutable;
  final String staticDir;
  final String templatesDir;
  final int memoryMaxBytes;
  final GuardConfig guards;
  final String logFormat;
  final String? logFile;
  final String logLevel;
  final List<String> redactPatterns;
  final List<String> agentDisallowedTools;
  final int? agentMaxTurns;
  final String? agentModel;
  final bool agentContext1m;
  final Map<String, dynamic>? agentAgents;
  final String gatewayAuthMode;
  final String? gatewayToken;
  final bool gatewayHsts;
  final int maxParallelTurns;
  final int sessionResetHour;
  final int sessionIdleTimeoutMinutes;
  final List<Map<String, dynamic>> schedulingJobs;
  final int contextReserveTokens;
  final int contextMaxResultBytes;
  final ContainerConfig containerConfig;
  final ChannelConfig channelConfig;
  final bool heartbeatEnabled;
  final int heartbeatIntervalMinutes;
  final bool gitSyncEnabled;
  final bool gitSyncPushEnabled;
  final List<AgentDefinition> agentDefinitions;
  final bool devMode;
  final String searchBackend;
  final String searchQmdHost;
  final int searchQmdPort;
  final String searchDefaultDepth;
  final bool contentGuardEnabled;
  final String contentGuardClassifier;
  final String contentGuardModel;
  final int contentGuardMaxBytes;
  final bool inputSanitizerEnabled;
  final bool inputSanitizerChannelsOnly;
  final int? usageBudgetWarningTokens;
  final int usageMaxFileSizeBytes;
  final bool memoryPruningEnabled;
  final int memoryArchiveAfterDays;
  final String memoryPruningSchedule;
  final Map<String, SearchProviderEntry> searchProviders;
  final SessionScopeConfig sessionScopeConfig;
  final SessionMaintenanceConfig sessionMaintenanceConfig;

  /// Raw guards YAML map for per-guard config (command, file, network sections).
  final Map<String, dynamic> guardsYaml;

  /// Warnings collected during [load] (unknown keys, type mismatches, etc.).
  /// Callers are responsible for surfacing these.
  final List<String> warnings;

  String get workspaceDir => p.join(dataDir, 'workspace');
  String get sessionsDir => p.join(dataDir, 'sessions');
  String get logsDir => p.join(dataDir, 'logs');
  String get searchDbPath => p.join(dataDir, 'search.db');
  String get kvPath => p.join(dataDir, 'kv.json');

  const DartclawConfig({
    this.port = 3000,
    this.host = 'localhost',
    this.name = 'DartClaw',
    this.dataDir = '~/.dartclaw',
    this.workerTimeout = 600,
    this.claudeExecutable = 'claude',
    this.staticDir = 'packages/dartclaw_server/lib/src/static',
    this.templatesDir = 'packages/dartclaw_server/lib/src/templates',
    this.memoryMaxBytes = 32 * 1024,
    this.guards = const GuardConfig.defaults(),
    this.logFormat = 'human',
    this.logFile,
    this.logLevel = 'INFO',
    this.redactPatterns = const [],
    this.agentDisallowedTools = const [],
    this.agentMaxTurns,
    this.agentModel,
    this.agentContext1m = false,
    this.agentAgents,
    this.gatewayAuthMode = 'token',
    this.gatewayToken,
    this.gatewayHsts = false,
    this.maxParallelTurns = 3,
    this.sessionResetHour = 4,
    this.sessionIdleTimeoutMinutes = 0,
    this.schedulingJobs = const [],
    this.contextReserveTokens = 20000,
    this.contextMaxResultBytes = 50 * 1024,
    this.containerConfig = const ContainerConfig.disabled(),
    this.channelConfig = const ChannelConfig.defaults(),
    this.heartbeatEnabled = true,
    this.heartbeatIntervalMinutes = 30,
    this.gitSyncEnabled = true,
    this.gitSyncPushEnabled = true,
    this.agentDefinitions = const [],
    this.devMode = false,
    this.searchBackend = 'fts5',
    this.searchQmdHost = '127.0.0.1',
    this.searchQmdPort = 8181,
    this.searchDefaultDepth = 'standard',
    this.contentGuardEnabled = true,
    this.contentGuardClassifier = 'claude_binary',
    this.contentGuardModel = 'claude-haiku-4-5-20251001',
    this.contentGuardMaxBytes = 50 * 1024,
    this.inputSanitizerEnabled = true,
    this.inputSanitizerChannelsOnly = true,
    this.usageBudgetWarningTokens,
    this.usageMaxFileSizeBytes = 10 * 1024 * 1024,
    this.memoryPruningEnabled = true,
    this.memoryArchiveAfterDays = 90,
    this.memoryPruningSchedule = '0 3 * * *',
    this.searchProviders = const {},
    this.sessionScopeConfig = const SessionScopeConfig.defaults(),
    this.sessionMaintenanceConfig = const SessionMaintenanceConfig.defaults(),
    this.guardsYaml = const {},
    this.warnings = const [],
  });

  /// All default values.
  const DartclawConfig.defaults() : this();

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
    final defaults = const DartclawConfig.defaults();

    // Find & read config file
    final yaml = _loadYaml(environment, reader, warns, configPath: configPath);

    // Parse each section
    final top = _parseTopLevel(yaml, cli, environment, defaults, warns);
    final logging = _parseLogging(yaml, cli, environment, defaults, warns);
    final agent = _parseAgent(yaml, defaults, warns);
    final gateway = _parseGateway(yaml, environment, defaults, warns);
    final sessions = _parseSessions(yaml, defaults, warns);
    final context = _parseContext(yaml, defaults, warns);
    final workspace = _parseWorkspace(yaml, defaults, warns);
    final scheduling = _parseScheduling(yaml, defaults, warns);
    final search = _parseSearch(yaml, environment, defaults, warns);
    final guards = _parseGuards(yaml, warns);
    final contentGuard = _parseContentGuard(yaml, defaults, warns);
    final inputSanitizer = _parseInputSanitizer(yaml, defaults, warns);
    final usage = _parseUsage(yaml, defaults, warns);
    final memory = _parseMemory(yaml, defaults, warns);
    final container = _parseContainer(yaml, warns);
    final channels = _parseChannels(yaml, warns);
    final concurrency = _parseConcurrency(yaml, defaults, warns);

    return DartclawConfig(
      port: top.port,
      host: top.host,
      name: top.name,
      dataDir: top.dataDir,
      workerTimeout: top.workerTimeout,
      claudeExecutable: top.claudeExecutable,
      staticDir: top.staticDir,
      templatesDir: top.templatesDir,
      memoryMaxBytes: top.memoryMaxBytes,
      guards: guards.config,
      guardsYaml: guards.yaml,
      logFormat: logging.logFormat,
      logFile: logging.logFile,
      logLevel: logging.logLevel,
      redactPatterns: logging.redactPatterns,
      agentDisallowedTools: agent.disallowedTools,
      agentMaxTurns: agent.maxTurns,
      agentModel: agent.model,
      agentContext1m: agent.context1m,
      agentAgents: agent.agents,
      agentDefinitions: agent.definitions,
      devMode: top.devMode,
      gatewayAuthMode: gateway.authMode,
      gatewayToken: gateway.token,
      gatewayHsts: gateway.hsts,
      maxParallelTurns: concurrency.maxParallelTurns,
      sessionResetHour: sessions.resetHour,
      sessionIdleTimeoutMinutes: sessions.idleTimeoutMinutes,
      sessionScopeConfig: sessions.scopeConfig,
      sessionMaintenanceConfig: sessions.maintenanceConfig,
      schedulingJobs: scheduling.jobs,
      heartbeatEnabled: scheduling.heartbeatEnabled,
      heartbeatIntervalMinutes: scheduling.heartbeatIntervalMinutes,
      contextReserveTokens: context.reserveTokens,
      contextMaxResultBytes: context.maxResultBytes,
      containerConfig: container,
      channelConfig: channels,
      gitSyncEnabled: workspace.gitSyncEnabled,
      gitSyncPushEnabled: workspace.gitSyncPushEnabled,
      searchBackend: search.backend,
      searchQmdHost: search.qmdHost,
      searchQmdPort: search.qmdPort,
      searchDefaultDepth: search.defaultDepth,
      searchProviders: search.providers,
      contentGuardEnabled: contentGuard.enabled,
      contentGuardClassifier: contentGuard.classifier,
      contentGuardModel: contentGuard.model,
      contentGuardMaxBytes: contentGuard.maxBytes,
      inputSanitizerEnabled: inputSanitizer.enabled,
      inputSanitizerChannelsOnly: inputSanitizer.channelsOnly,
      usageBudgetWarningTokens: usage.budgetWarningTokens,
      usageMaxFileSizeBytes: usage.maxFileSizeBytes,
      memoryPruningEnabled: memory.pruningEnabled,
      memoryArchiveAfterDays: memory.archiveAfterDays,
      memoryPruningSchedule: memory.pruningSchedule,
      warnings: List.unmodifiable(warns),
    );
  }

  // ---------------------------------------------------------------------------
  // Section parse methods — each returns a named record
  // ---------------------------------------------------------------------------

  static ({
    int port,
    String host,
    String name,
    String dataDir,
    int workerTimeout,
    String claudeExecutable,
    String staticDir,
    String templatesDir,
    int memoryMaxBytes,
    bool devMode,
  })
  _parseTopLevel(
    Map<String, dynamic> yaml,
    Map<String, String> cli,
    Map<String, String> env,
    DartclawConfig defaults,
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

    final memoryMaxBytes = _parseInt(
      'memory_max_bytes',
      cli['memory_max_bytes'],
      yaml['memory_max_bytes'],
      defaults.memoryMaxBytes,
      warns,
    );

    // claudeExecutable, staticDir, templatesDir: CLI only (not from YAML)
    final claudeExecutable = cli['claude_executable'] ?? defaults.claudeExecutable;
    final staticDir = cli['static_dir'] ?? defaults.staticDir;
    final templatesDir = cli['templates_dir'] ?? defaults.templatesDir;

    // dev_mode: enables template hot-reload, etc.
    final devMode = yaml['dev_mode'] == true || cli['dev_mode'] == 'true';

    return (
      port: port,
      host: host,
      name: name,
      dataDir: dataDir,
      workerTimeout: workerTimeout,
      claudeExecutable: claudeExecutable,
      staticDir: staticDir,
      templatesDir: templatesDir,
      memoryMaxBytes: memoryMaxBytes,
      devMode: devMode,
    );
  }

  static ({String logFormat, String? logFile, String logLevel, List<String> redactPatterns}) _parseLogging(
    Map<String, dynamic> yaml,
    Map<String, String> cli,
    Map<String, String> env,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var logFormat = cli['log_format'] ?? defaults.logFormat;
    String? logFile = cli['log_file'];
    var logLevel = cli['log_level'] ?? defaults.logLevel;
    var redactPatterns = defaults.redactPatterns;

    final loggingRaw = yaml['logging'];
    if (loggingRaw != null) {
      if (loggingRaw is Map) {
        final logMap = Map<String, dynamic>.from(loggingRaw);
        if (cli['log_format'] == null && logMap['format'] is String) {
          logFormat = logMap['format'] as String;
        }
        if (cli['log_file'] == null && logMap['file'] is String) {
          logFile = envSubstitute(logMap['file'] as String, env: env);
        }
        if (cli['log_level'] == null && logMap['level'] is String) {
          logLevel = logMap['level'] as String;
        }
        final patternsRaw = logMap['redact_patterns'];
        if (patternsRaw is List) {
          redactPatterns = patternsRaw.whereType<String>().toList();
        }
      } else {
        warns.add('Invalid type for logging: "${loggingRaw.runtimeType}" — using defaults');
      }
    }

    return (logFormat: logFormat, logFile: logFile, logLevel: logLevel, redactPatterns: redactPatterns);
  }

  static ({
    List<String> disallowedTools,
    int? maxTurns,
    String? model,
    bool context1m,
    Map<String, dynamic>? agents,
    List<AgentDefinition> definitions,
  })
  _parseAgent(Map<String, dynamic> yaml, DartclawConfig defaults, List<String> warns) {
    var disallowedTools = defaults.agentDisallowedTools;
    int? maxTurns = defaults.agentMaxTurns;
    String? model = defaults.agentModel;
    var context1m = defaults.agentContext1m;
    Map<String, dynamic>? agents = defaults.agentAgents;

    final agentRaw = yaml['agent'];
    if (agentRaw != null) {
      if (agentRaw is Map) {
        final agentMap = Map<String, dynamic>.from(agentRaw);
        final disallowed = agentMap['disallowed_tools'];
        if (disallowed is List) {
          disallowedTools = disallowed.whereType<String>().toList();
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
        final ctx = agentMap['context_1m'];
        if (ctx is bool) {
          context1m = ctx;
        }
        final agentsVal = agentMap['agents'];
        if (agentsVal is Map) {
          agents = Map<String, dynamic>.from(agentsVal);
        }
      } else {
        warns.add('Invalid type for agent: "${agentRaw.runtimeType}" — using defaults');
      }
    }

    // Parse structured agent definitions from agent.agents
    final definitions = <AgentDefinition>[];
    if (agents != null) {
      for (final entry in agents.entries) {
        final id = entry.key;
        final value = entry.value;
        if (value is Map) {
          definitions.add(AgentDefinition.fromYaml(id, Map<String, dynamic>.from(value), warns));
        }
      }
    }

    return (
      disallowedTools: disallowedTools,
      maxTurns: maxTurns,
      model: model,
      context1m: context1m,
      agents: agents,
      definitions: definitions,
    );
  }

  static ({String authMode, String? token, bool hsts}) _parseGateway(
    Map<String, dynamic> yaml,
    Map<String, String> env,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var authMode = defaults.gatewayAuthMode;
    String? token = defaults.gatewayToken;
    var hsts = defaults.gatewayHsts;

    final gatewayRaw = yaml['gateway'];
    if (gatewayRaw != null) {
      if (gatewayRaw is Map) {
        final gMap = Map<String, dynamic>.from(gatewayRaw);
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
      } else {
        warns.add('Invalid type for gateway: "${gatewayRaw.runtimeType}" — using defaults');
      }
    }

    return (authMode: authMode, token: token, hsts: hsts);
  }

  static ({
    int resetHour,
    int idleTimeoutMinutes,
    SessionScopeConfig scopeConfig,
    SessionMaintenanceConfig maintenanceConfig,
  })
  _parseSessions(Map<String, dynamic> yaml, DartclawConfig defaults, List<String> warns) {
    var resetHour = defaults.sessionResetHour;
    var idleTimeoutMinutes = defaults.sessionIdleTimeoutMinutes;
    var scopeConfig = defaults.sessionScopeConfig;
    var maintenanceConfig = defaults.sessionMaintenanceConfig;

    final sessionsRaw = yaml['sessions'];
    if (sessionsRaw is Map) {
      resetHour = _parseInt('sessions.reset_hour', null, sessionsRaw['reset_hour'], defaults.sessionResetHour, warns);
      idleTimeoutMinutes = _parseInt(
        'sessions.idle_timeout_minutes',
        null,
        sessionsRaw['idle_timeout_minutes'],
        defaults.sessionIdleTimeoutMinutes,
        warns,
      );
      scopeConfig = _parseSessionScope(sessionsRaw, defaults, warns);
      maintenanceConfig = _parseSessionMaintenance(sessionsRaw, defaults, warns);
    } else if (sessionsRaw != null) {
      warns.add('Invalid type for sessions: "${sessionsRaw.runtimeType}" — using defaults');
    }

    return (
      resetHour: resetHour,
      idleTimeoutMinutes: idleTimeoutMinutes,
      scopeConfig: scopeConfig,
      maintenanceConfig: maintenanceConfig,
    );
  }

  static SessionScopeConfig _parseSessionScope(
    Map<dynamic, dynamic> sessionsRaw,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    final defaultScope = defaults.sessionScopeConfig;

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
    DartclawConfig defaults,
    List<String> warns,
  ) {
    final defaultMaint = defaults.sessionMaintenanceConfig;

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

  static ({int reserveTokens, int maxResultBytes}) _parseContext(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var reserveTokens = defaults.contextReserveTokens;
    var maxResultBytes = defaults.contextMaxResultBytes;

    final contextRaw = yaml['context'];
    if (contextRaw is Map) {
      reserveTokens = _parseInt(
        'context.reserve_tokens',
        null,
        contextRaw['reserve_tokens'],
        defaults.contextReserveTokens,
        warns,
      );
      maxResultBytes = _parseInt(
        'context.max_result_bytes',
        null,
        contextRaw['max_result_bytes'],
        defaults.contextMaxResultBytes,
        warns,
      );
    } else if (contextRaw != null) {
      warns.add('Invalid type for context: "${contextRaw.runtimeType}" — using defaults');
    }

    return (reserveTokens: reserveTokens, maxResultBytes: maxResultBytes);
  }

  static ({bool gitSyncEnabled, bool gitSyncPushEnabled}) _parseWorkspace(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var gitSyncEnabled = defaults.gitSyncEnabled;
    var gitSyncPushEnabled = defaults.gitSyncPushEnabled;

    final workspaceRaw = yaml['workspace'];
    if (workspaceRaw is Map) {
      final gsRaw = workspaceRaw['git_sync'];
      if (gsRaw is Map) {
        final en = gsRaw['enabled'];
        if (en is bool) gitSyncEnabled = en;
        final pe = gsRaw['push_enabled'];
        if (pe is bool) gitSyncPushEnabled = pe;
      }
    } else if (workspaceRaw != null) {
      warns.add('Invalid type for workspace: "${workspaceRaw.runtimeType}" — using defaults');
    }

    return (gitSyncEnabled: gitSyncEnabled, gitSyncPushEnabled: gitSyncPushEnabled);
  }

  static ({List<Map<String, dynamic>> jobs, bool heartbeatEnabled, int heartbeatIntervalMinutes}) _parseScheduling(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var jobs = <Map<String, dynamic>>[];
    var heartbeatEnabled = defaults.heartbeatEnabled;
    var heartbeatIntervalMinutes = defaults.heartbeatIntervalMinutes;

    final schedulingRaw = yaml['scheduling'];
    if (schedulingRaw is Map) {
      final jobsRaw = schedulingRaw['jobs'];
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
      final hbRaw = schedulingRaw['heartbeat'];
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
    } else if (schedulingRaw != null) {
      warns.add('Invalid type for scheduling: "${schedulingRaw.runtimeType}" — using defaults');
    }

    return (jobs: jobs, heartbeatEnabled: heartbeatEnabled, heartbeatIntervalMinutes: heartbeatIntervalMinutes);
  }

  static ({
    String backend,
    String qmdHost,
    int qmdPort,
    String defaultDepth,
    Map<String, SearchProviderEntry> providers,
  })
  _parseSearch(Map<String, dynamic> yaml, Map<String, String> env, DartclawConfig defaults, List<String> warns) {
    final providers = <String, SearchProviderEntry>{};
    var backend = defaults.searchBackend;
    var qmdHost = defaults.searchQmdHost;
    var qmdPort = defaults.searchQmdPort;
    var defaultDepth = defaults.searchDefaultDepth;

    final searchRaw = yaml['search'];
    if (searchRaw is Map) {
      final backendVal = searchRaw['backend'];
      if (backendVal is String && (backendVal == 'fts5' || backendVal == 'qmd')) {
        backend = backendVal;
      } else if (backendVal != null) {
        warns.add('Invalid search.backend: "$backendVal" — using default');
      }
      final qmdRaw = searchRaw['qmd'];
      if (qmdRaw is Map) {
        final h = qmdRaw['host'];
        if (h is String) qmdHost = h;
        qmdPort = _parseInt('search.qmd.port', null, qmdRaw['port'], defaults.searchQmdPort, warns);
      }
      final depth = searchRaw['default_depth'];
      if (depth is String) defaultDepth = depth;

      // Search providers (brave, tavily, etc.)
      final providersRaw = searchRaw['providers'];
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
    } else if (searchRaw != null) {
      warns.add('Invalid type for search: "${searchRaw.runtimeType}" — using defaults');
    }

    return (backend: backend, qmdHost: qmdHost, qmdPort: qmdPort, defaultDepth: defaultDepth, providers: providers);
  }

  static ({GuardConfig config, Map<String, dynamic> yaml}) _parseGuards(
    Map<String, dynamic> yamlValues,
    List<String> warns,
  ) {
    final guardsRaw = yamlValues['guards'];
    final guardsYaml = guardsRaw is Map ? Map<String, dynamic>.from(guardsRaw) : <String, dynamic>{};
    GuardConfig config;
    if (guardsRaw is Map) {
      try {
        config = GuardConfig.fromYaml(Map<String, dynamic>.from(guardsRaw), warns);
      } catch (e) {
        warns.add('Error parsing guards config: $e — using defaults');
        config = const GuardConfig.defaults();
      }
    } else {
      if (guardsRaw != null) {
        warns.add('Invalid type for guards: "${guardsRaw.runtimeType}" — using defaults');
      }
      config = const GuardConfig.defaults();
    }
    return (config: config, yaml: guardsYaml);
  }

  static ({bool enabled, String classifier, String model, int maxBytes}) _parseContentGuard(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var enabled = defaults.contentGuardEnabled;
    var classifier = defaults.contentGuardClassifier;
    var model = defaults.contentGuardModel;
    var maxBytes = defaults.contentGuardMaxBytes;

    final guardsRaw = yaml['guards'];
    if (guardsRaw is Map) {
      final contentRaw = guardsRaw['content'];
      if (contentRaw is Map) {
        final en = contentRaw['enabled'];
        if (en is bool) enabled = en;
        final classifierVal = contentRaw['classifier'];
        if (classifierVal is String) {
          if (classifierVal == 'claude_binary' || classifierVal == 'anthropic_api') {
            classifier = classifierVal;
          } else {
            warns.add('Invalid guards.content.classifier: "$classifierVal" — using default');
          }
        }
        final modelVal = contentRaw['model'];
        if (modelVal is String) model = modelVal;
        maxBytes = _parseInt(
          'guards.content.max_bytes',
          null,
          contentRaw['max_bytes'],
          defaults.contentGuardMaxBytes,
          warns,
        );
      }
    }

    return (enabled: enabled, classifier: classifier, model: model, maxBytes: maxBytes);
  }

  static ({bool enabled, bool channelsOnly}) _parseInputSanitizer(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var enabled = defaults.inputSanitizerEnabled;
    var channelsOnly = defaults.inputSanitizerChannelsOnly;

    final guardsRaw = yaml['guards'];
    if (guardsRaw is Map) {
      final isRaw = guardsRaw['input_sanitizer'];
      if (isRaw is Map) {
        final en = isRaw['enabled'];
        if (en is bool) enabled = en;
        final co = isRaw['channels_only'];
        if (co is bool) channelsOnly = co;
      }
    }

    return (enabled: enabled, channelsOnly: channelsOnly);
  }

  static ({int? budgetWarningTokens, int maxFileSizeBytes}) _parseUsage(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    int? budgetWarningTokens = defaults.usageBudgetWarningTokens;
    var maxFileSizeBytes = defaults.usageMaxFileSizeBytes;

    final usageRaw = yaml['usage'];
    if (usageRaw is Map) {
      final bwt = usageRaw['budget_warning_tokens'];
      if (bwt is int) {
        budgetWarningTokens = bwt;
      } else if (bwt != null) {
        warns.add('Invalid type for usage.budget_warning_tokens: "${bwt.runtimeType}" — ignoring');
      }
      maxFileSizeBytes = _parseInt(
        'usage.max_file_size_bytes',
        null,
        usageRaw['max_file_size_bytes'],
        defaults.usageMaxFileSizeBytes,
        warns,
      );
    } else if (usageRaw != null) {
      warns.add('Invalid type for usage: "${usageRaw.runtimeType}" — using defaults');
    }

    return (budgetWarningTokens: budgetWarningTokens, maxFileSizeBytes: maxFileSizeBytes);
  }

  static ({bool pruningEnabled, int archiveAfterDays, String pruningSchedule}) _parseMemory(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    var pruningEnabled = defaults.memoryPruningEnabled;
    var archiveAfterDays = defaults.memoryArchiveAfterDays;
    var pruningSchedule = defaults.memoryPruningSchedule;

    final memoryRaw = yaml['memory'];
    if (memoryRaw is Map) {
      final pruningRaw = memoryRaw['pruning'];
      if (pruningRaw is Map) {
        final en = pruningRaw['enabled'];
        if (en is bool) pruningEnabled = en;
        archiveAfterDays = _parseInt(
          'memory.pruning.archive_after_days',
          null,
          pruningRaw['archive_after_days'],
          defaults.memoryArchiveAfterDays,
          warns,
        );
        final sched = pruningRaw['schedule'];
        if (sched is String) pruningSchedule = sched;
      }
    } else if (memoryRaw != null) {
      warns.add('Invalid type for memory: "${memoryRaw.runtimeType}" — using defaults');
    }

    return (pruningEnabled: pruningEnabled, archiveAfterDays: archiveAfterDays, pruningSchedule: pruningSchedule);
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

  static ({int maxParallelTurns}) _parseConcurrency(
    Map<String, dynamic> yaml,
    DartclawConfig defaults,
    List<String> warns,
  ) {
    final maxParallelTurns = _parseInt(
      'concurrency.max_parallel_turns',
      null,
      (yaml['concurrency'] is Map) ? (yaml['concurrency'] as Map)['max_parallel_turns'] : null,
      defaults.maxParallelTurns,
      warns,
    );
    return (maxParallelTurns: maxParallelTurns);
  }

  // --- Private helpers ---

  static String? _defaultFileReader(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  static String _homeDir(Map<String, String> env) {
    return env['HOME'] ?? env['USERPROFILE'] ?? '.';
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
    'gateway',
    'concurrency',
    'sessions',
    'scheduling',
    'context',
    'container',
    'channels',
    'workspace',
    'search',
    'usage',
    'memory',
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
      content = reader(configPath);
      if (content == null) {
        warns.add('--config points to non-existent file: $configPath — using defaults');
        return {};
      }
    } else {
      final envPath = env['DARTCLAW_CONFIG'];
      if (envPath != null) {
        content = reader(envPath);
        if (content == null) {
          warns.add('DARTCLAW_CONFIG points to non-existent file: $envPath — using defaults');
          return {};
        }
      } else {
        content = reader('dartclaw.yaml');
        content ??= reader(p.join(_homeDir(env), '.dartclaw', 'dartclaw.yaml'));
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
        warns.add('Unknown config key: $key');
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

/// Configuration for a single search provider (e.g. Brave, Tavily).
class SearchProviderEntry {
  final bool enabled;
  final String apiKey;

  const SearchProviderEntry({required this.enabled, required this.apiKey});
}
