import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../agents/agent_definition.dart';
import '../channel/channel_config.dart';
import '../container/container_config.dart';
import '../security/env_substitute.dart';
import '../security/guard_config.dart';

/// Immutable configuration for DartClaw runtime.
class DartclawConfig {
  final int port;
  final String host;
  final String dataDir;
  final int workerTimeout;
  final String claudeExecutable;
  final String staticDir;
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
  final String searchBackend;
  final String searchQmdHost;
  final int searchQmdPort;
  final String searchDefaultDepth;
  final bool contentGuardEnabled;
  final String contentGuardModel;
  final int contentGuardMaxBytes;

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
    this.dataDir = '~/.dartclaw',
    this.workerTimeout = 600,
    this.claudeExecutable = 'claude',
    this.staticDir = 'packages/dartclaw_server/lib/src/static',
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
    this.searchBackend = 'fts5',
    this.searchQmdHost = '127.0.0.1',
    this.searchQmdPort = 8181,
    this.searchDefaultDepth = 'standard',
    this.contentGuardEnabled = true,
    this.contentGuardModel = 'claude-haiku-4-5-20251001',
    this.contentGuardMaxBytes = 50 * 1024,
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

    // Find & read config file
    final yamlValues = _loadYaml(environment, reader, warns, configPath: configPath);

    // Merge: CLI > YAML > defaults (for YAML-allowed keys only)
    final defaults = const DartclawConfig.defaults();

    final port = _parseInt('port', cli['port'], yamlValues['port'], defaults.port, warns);
    final host = _parseString('host', cli['host'], yamlValues['host'], defaults.host, environment, warns);
    final workerTimeout = _parseInt(
      'worker_timeout',
      cli['worker_timeout'],
      yamlValues['worker_timeout'],
      defaults.workerTimeout,
      warns,
    );

    // dataDir: CLI > YAML > default, with ~ expansion
    final rawDataDir =
        cli['data_dir'] ?? _yamlString('data_dir', yamlValues['data_dir'], defaults.dataDir, environment, warns);
    final dataDir = _expandHome(rawDataDir, environment);

    final memoryMaxBytes = _parseInt(
      'memory_max_bytes',
      cli['memory_max_bytes'],
      yamlValues['memory_max_bytes'],
      defaults.memoryMaxBytes,
      warns,
    );

    // claudeExecutable and staticDir: CLI only (not from YAML)
    final claudeExecutable = cli['claude_executable'] ?? defaults.claudeExecutable;
    final staticDir = cli['static_dir'] ?? defaults.staticDir;

    // Guards config: nested map from YAML
    final guardsRaw = yamlValues['guards'];
    final guardsYaml = guardsRaw is Map ? Map<String, dynamic>.from(guardsRaw) : <String, dynamic>{};
    GuardConfig guards;
    if (guardsRaw is Map) {
      try {
        guards = GuardConfig.fromYaml(Map<String, dynamic>.from(guardsRaw), warns);
      } catch (e) {
        warns.add('Error parsing guards config: $e — using defaults');
        guards = const GuardConfig.defaults();
      }
    } else if (guardsRaw != null) {
      warns.add('Invalid type for guards: "${guardsRaw.runtimeType}" — using defaults');
      guards = const GuardConfig.defaults();
    } else {
      guards = const GuardConfig.defaults();
    }

    // Logging config: nested map from YAML, CLI overrides
    var logFormat = cli['log_format'] ?? defaults.logFormat;
    String? logFile = cli['log_file'];
    var logLevel = cli['log_level'] ?? defaults.logLevel;
    var redactPatterns = defaults.redactPatterns;

    final loggingRaw = yamlValues['logging'];
    if (loggingRaw != null) {
      if (loggingRaw is Map) {
        final logMap = Map<String, dynamic>.from(loggingRaw);
        if (cli['log_format'] == null && logMap['format'] is String) {
          logFormat = logMap['format'] as String;
        }
        if (cli['log_file'] == null && logMap['file'] is String) {
          logFile = envSubstitute(logMap['file'] as String, env: environment);
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

    // Agent config: nested map from YAML
    var agentDisallowedTools = defaults.agentDisallowedTools;
    int? agentMaxTurns = defaults.agentMaxTurns;
    String? agentModel = defaults.agentModel;
    var agentContext1m = defaults.agentContext1m;
    Map<String, dynamic>? agentAgents = defaults.agentAgents;

    final agentRaw = yamlValues['agent'];
    if (agentRaw != null) {
      if (agentRaw is Map) {
        final agentMap = Map<String, dynamic>.from(agentRaw);
        final disallowed = agentMap['disallowed_tools'];
        if (disallowed is List) {
          agentDisallowedTools = disallowed.whereType<String>().toList();
        }
        final mt = agentMap['max_turns'];
        if (mt is int) {
          agentMaxTurns = mt;
        } else if (mt != null) {
          warns.add('Invalid type for agent.max_turns: "${mt.runtimeType}" — ignoring');
        }
        final model = agentMap['model'];
        if (model is String) {
          agentModel = model;
        } else if (model != null) {
          warns.add('Invalid type for agent.model: "${model.runtimeType}" — ignoring');
        }
        final ctx = agentMap['context_1m'];
        if (ctx is bool) {
          agentContext1m = ctx;
        }
        final agents = agentMap['agents'];
        if (agents is Map) {
          agentAgents = Map<String, dynamic>.from(agents);
        }
      } else {
        warns.add('Invalid type for agent: "${agentRaw.runtimeType}" — using defaults');
      }
    }

    // Parse structured agent definitions from agent.agents
    final agentDefinitions = <AgentDefinition>[];
    if (agentAgents != null) {
      for (final entry in agentAgents.entries) {
        final id = entry.key;
        final value = entry.value;
        if (value is Map) {
          agentDefinitions.add(AgentDefinition.fromYaml(id, Map<String, dynamic>.from(value), warns));
        }
      }
    }

    // Gateway config: nested map from YAML
    var gatewayAuthMode = defaults.gatewayAuthMode;
    String? gatewayToken = defaults.gatewayToken;

    final gatewayRaw = yamlValues['gateway'];
    if (gatewayRaw != null) {
      if (gatewayRaw is Map) {
        final gMap = Map<String, dynamic>.from(gatewayRaw);
        final mode = gMap['auth_mode'];
        if (mode is String) {
          if (mode == 'token' || mode == 'none') {
            gatewayAuthMode = mode;
          } else {
            warns.add('Invalid gateway.auth_mode: "$mode" — using default');
          }
        } else if (mode != null) {
          warns.add('Invalid type for gateway.auth_mode: "${mode.runtimeType}" — using default');
        }
        final token = gMap['token'];
        if (token is String && token.isNotEmpty) {
          gatewayToken = envSubstitute(token, env: environment);
        } else if (token != null && token is! String) {
          warns.add('Invalid type for gateway.token: "${token.runtimeType}" — ignoring');
        }
      } else {
        warns.add('Invalid type for gateway: "${gatewayRaw.runtimeType}" — using defaults');
      }
    }

    // Concurrency config
    final maxParallelTurns = _parseInt(
      'concurrency.max_parallel_turns',
      null,
      (yamlValues['concurrency'] is Map) ? (yamlValues['concurrency'] as Map)['max_parallel_turns'] : null,
      defaults.maxParallelTurns,
      warns,
    );

    // Sessions config
    var sessionResetHour = defaults.sessionResetHour;
    var sessionIdleTimeoutMinutes = defaults.sessionIdleTimeoutMinutes;
    final sessionsRaw = yamlValues['sessions'];
    if (sessionsRaw is Map) {
      sessionResetHour = _parseInt(
        'sessions.reset_hour',
        null,
        sessionsRaw['reset_hour'],
        defaults.sessionResetHour,
        warns,
      );
      sessionIdleTimeoutMinutes = _parseInt(
        'sessions.idle_timeout_minutes',
        null,
        sessionsRaw['idle_timeout_minutes'],
        defaults.sessionIdleTimeoutMinutes,
        warns,
      );
    } else if (sessionsRaw != null) {
      warns.add('Invalid type for sessions: "${sessionsRaw.runtimeType}" — using defaults');
    }

    // Context config
    var contextReserveTokens = defaults.contextReserveTokens;
    var contextMaxResultBytes = defaults.contextMaxResultBytes;
    final contextRaw = yamlValues['context'];
    if (contextRaw is Map) {
      contextReserveTokens = _parseInt(
        'context.reserve_tokens',
        null,
        contextRaw['reserve_tokens'],
        defaults.contextReserveTokens,
        warns,
      );
      contextMaxResultBytes = _parseInt(
        'context.max_result_bytes',
        null,
        contextRaw['max_result_bytes'],
        defaults.contextMaxResultBytes,
        warns,
      );
    } else if (contextRaw != null) {
      warns.add('Invalid type for context: "${contextRaw.runtimeType}" — using defaults');
    }

    // Container config
    final containerRaw = yamlValues['container'];
    final containerConfig = containerRaw is Map
        ? ContainerConfig.fromYaml(Map<String, dynamic>.from(containerRaw), warns)
        : const ContainerConfig.disabled();
    if (containerRaw != null && containerRaw is! Map) {
      warns.add('Invalid type for container: "${containerRaw.runtimeType}" — using defaults');
    }

    // Channels config
    final channelsRaw = yamlValues['channels'];
    final channelConfig = channelsRaw is Map
        ? ChannelConfig.fromYaml(Map<String, dynamic>.from(channelsRaw), warns)
        : const ChannelConfig.defaults();
    if (channelsRaw != null && channelsRaw is! Map) {
      warns.add('Invalid type for channels: "${channelsRaw.runtimeType}" — using defaults');
    }

    // Workspace config (git sync)
    var gitSyncEnabled = defaults.gitSyncEnabled;
    var gitSyncPushEnabled = defaults.gitSyncPushEnabled;
    final workspaceRaw = yamlValues['workspace'];
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

    // Scheduling config: list of job maps
    var schedulingJobs = <Map<String, dynamic>>[];
    final schedulingRaw = yamlValues['scheduling'];
    if (schedulingRaw is Map) {
      final jobsRaw = schedulingRaw['jobs'];
      if (jobsRaw is List) {
        for (final entry in jobsRaw) {
          if (entry is Map) {
            schedulingJobs.add(Map<String, dynamic>.from(entry));
          } else {
            warns.add('Invalid scheduling job entry: "${entry.runtimeType}" — skipping');
          }
        }
      } else if (jobsRaw != null) {
        warns.add('Invalid type for scheduling.jobs: "${jobsRaw.runtimeType}" — expected list');
      }
    } else if (schedulingRaw != null) {
      warns.add('Invalid type for scheduling: "${schedulingRaw.runtimeType}" — using defaults');
    }

    // Heartbeat config (under scheduling.heartbeat)
    var heartbeatEnabled = defaults.heartbeatEnabled;
    var heartbeatIntervalMinutes = defaults.heartbeatIntervalMinutes;
    if (schedulingRaw is Map) {
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
    }

    // Search config
    var searchBackend = defaults.searchBackend;
    var searchQmdHost = defaults.searchQmdHost;
    var searchQmdPort = defaults.searchQmdPort;
    var searchDefaultDepth = defaults.searchDefaultDepth;
    final searchRaw = yamlValues['search'];
    if (searchRaw is Map) {
      final backend = searchRaw['backend'];
      if (backend is String && (backend == 'fts5' || backend == 'qmd')) {
        searchBackend = backend;
      } else if (backend != null) {
        warns.add('Invalid search.backend: "$backend" — using default');
      }
      final qmdRaw = searchRaw['qmd'];
      if (qmdRaw is Map) {
        final h = qmdRaw['host'];
        if (h is String) searchQmdHost = h;
        searchQmdPort = _parseInt('search.qmd.port', null, qmdRaw['port'], defaults.searchQmdPort, warns);
      }
      final depth = searchRaw['default_depth'];
      if (depth is String) searchDefaultDepth = depth;
    } else if (searchRaw != null) {
      warns.add('Invalid type for search: "${searchRaw.runtimeType}" — using defaults');
    }

    // Content-guard config (under guards.content)
    var contentGuardEnabled = defaults.contentGuardEnabled;
    var contentGuardModel = defaults.contentGuardModel;
    var contentGuardMaxBytes = defaults.contentGuardMaxBytes;
    if (guardsRaw is Map) {
      final contentRaw = guardsRaw['content'];
      if (contentRaw is Map) {
        final en = contentRaw['enabled'];
        if (en is bool) contentGuardEnabled = en;
        final model = contentRaw['model'];
        if (model is String) contentGuardModel = model;
        contentGuardMaxBytes = _parseInt(
          'guards.content.max_bytes',
          null,
          contentRaw['max_bytes'],
          defaults.contentGuardMaxBytes,
          warns,
        );
      }
    }

    return DartclawConfig(
      port: port,
      host: host,
      dataDir: dataDir,
      workerTimeout: workerTimeout,
      claudeExecutable: claudeExecutable,
      staticDir: staticDir,
      memoryMaxBytes: memoryMaxBytes,
      guards: guards,
      logFormat: logFormat,
      logFile: logFile,
      logLevel: logLevel,
      redactPatterns: redactPatterns,
      agentDisallowedTools: agentDisallowedTools,
      agentMaxTurns: agentMaxTurns,
      agentModel: agentModel,
      agentContext1m: agentContext1m,
      agentAgents: agentAgents,
      gatewayAuthMode: gatewayAuthMode,
      gatewayToken: gatewayToken,
      maxParallelTurns: maxParallelTurns,
      sessionResetHour: sessionResetHour,
      sessionIdleTimeoutMinutes: sessionIdleTimeoutMinutes,
      schedulingJobs: schedulingJobs,
      contextReserveTokens: contextReserveTokens,
      contextMaxResultBytes: contextMaxResultBytes,
      containerConfig: containerConfig,
      channelConfig: channelConfig,
      heartbeatEnabled: heartbeatEnabled,
      heartbeatIntervalMinutes: heartbeatIntervalMinutes,
      gitSyncEnabled: gitSyncEnabled,
      gitSyncPushEnabled: gitSyncPushEnabled,
      agentDefinitions: agentDefinitions,
      searchBackend: searchBackend,
      searchQmdHost: searchQmdHost,
      searchQmdPort: searchQmdPort,
      searchDefaultDepth: searchDefaultDepth,
      contentGuardEnabled: contentGuardEnabled,
      contentGuardModel: contentGuardModel,
      contentGuardMaxBytes: contentGuardMaxBytes,
      guardsYaml: guardsYaml,
      warnings: List.unmodifiable(warns),
    );
  }

  // --- Private helpers ---

  static String? _defaultFileReader(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  static String _homeDir(Map<String, String> env) {
    return env['HOME'] ?? env['USERPROFILE'] ?? '.';
  }

  static String _expandHome(String value, Map<String, String> env) {
    if (value.startsWith('~/') || value == '~') {
      return p.join(_homeDir(env), value.substring(value.length == 1 ? 1 : 2));
    }
    return value;
  }

  static const _knownKeys = {
    'port',
    'host',
    'data_dir',
    'worker_timeout',
    'memory_max_bytes',
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
