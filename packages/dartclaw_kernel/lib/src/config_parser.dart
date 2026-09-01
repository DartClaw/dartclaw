part of 'dartclaw_config.dart';

final _recognizedClaudeModels = RegExp(
  r'^(default|haiku|sonnet|opus|opusplan)(\[[^\]]+\])?$|^(claude-[a-z0-9][a-z0-9.\-]*|anthropic\.claude-[a-z0-9.\-]+(@[a-z0-9.\-]+)?)$',
  caseSensitive: false,
);
const _invalidYamlRoot = FormatException('YAML configuration root must be a map — refusing to start with defaults');
const _recognizedCodexModels = <String>{
  'gpt-5.4',
  'gpt-5.4-mini',
  'gpt-5.4-nano',
  'gpt-5.6-luna',
  'gpt-5',
  'gpt-5-mini',
  'gpt-5-nano',
  'gpt-5-codex',
  'gpt-5.3-codex',
  'gpt-5.2-codex',
  'gpt-5.1-codex',
  'gpt-5.1-codex-max',
  'gpt-5.1-codex-mini',
  'codex-mini-latest',
  'o1',
  'o3',
  'o4-mini',
};

const _knownKeys = {
  'port',
  'host',
  'name',
  'data_dir',
  'source_dir',
  'static_dir',
  'templates_dir',
  'base_url',
  'memory_max_bytes',
  'dev_mode',
  'guards',
  'logging',
  'agent',
  'auth',
  'gateway',
  'harness',
  'concurrency',
  'sessions',
  'scheduling',
  'context',
  'container',
  'channels',
  'providers',
  'credentials',
  'mcp_servers',
  'workspace',
  'onboarding',
  'workflow',
  'search',
  'usage',
  'guard_audit',
  'memory',
  'knowledge',
  'tasks',
  'automation',
  'governance',
  'features',
  'projects',
  'alerts',
  'security',
  'andthen',
  'delegation',
};

String? _defaultFileReader(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : null;
}

Map<String, dynamic> _loadYaml(
  Map<String, String> env,
  String? Function(String) reader,
  List<String> warns, {
  String? configPath,
}) {
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
      // Check for CWD-based config (deprecated in 0.16.2) and emit a warning.
      // The new discovery order no longer includes CWD. Explicit external-config
      // mode is still supported via --config or DARTCLAW_CONFIG.
      final cwdContent = reader('dartclaw.yaml');
      if (cwdContent != null) {
        addConfigAdvisory(
          warns,
          'Found dartclaw.yaml in the current directory, but CWD config discovery is deprecated. '
          'Use --config ./dartclaw.yaml or move it to ~/.dartclaw/dartclaw.yaml. '
          'See: https://dartclaw.dev/guide/configuration#instance-directory',
        );
      }

      // DARTCLAW_HOME points at an instance directory, not a config file.
      final homeEnv = env['DARTCLAW_HOME'];
      if (homeEnv != null) {
        final homeConfigPath = p.join(expandHome(homeEnv, env: env), 'dartclaw.yaml');
        content = reader(homeConfigPath);
        if (content == null) {
          warns.add('DARTCLAW_HOME points to a directory with no dartclaw.yaml: $homeEnv — using defaults');
          return {};
        }
      } else {
        // Default: ~/.dartclaw/dartclaw.yaml
        content = reader(p.join(env['HOME'] ?? env['USERPROFILE'] ?? '.', '.dartclaw', 'dartclaw.yaml'));
      }
    }
  }

  if (content == null) return {};

  Object? doc;
  try {
    doc = loadYaml(content);
  } on YamlException catch (e) {
    // A malformed document must fail startup: silently falling back to
    // defaults would boot a container-enabled deployment fully unisolated.
    throw FormatException('YAML parse error in configuration — refusing to start with defaults: $e');
  }

  if (doc == null) return {};
  if (doc is! YamlMap && doc is! Map) {
    throw _invalidYamlRoot;
  }

  final map = doc as Map;
  final result = <String, dynamic>{};

  for (final entry in map.entries) {
    final key = entry.key.toString();
    if (!_knownKeys.contains(key)) {
      result[key] = entry.value;
      continue;
    }
    if (entry.value == null) {
      warns.add('Config key "$key" is null — using default');
      continue;
    }
    result[key] = entry.value;
  }

  _rejectRetiredTurnLimitKeys(result);

  final sweep = _sweepConfigPaths(
    result,
    extensionKeys: _registeredExtensionKeys(),
    fields: ConfigMeta.fields,
    tolerated: ConfigMeta.toleratedLegacyKeys,
  );
  if (sweep.unaccepted.isNotEmpty) throw _unknownConfigFields(sweep.unaccepted);
  for (final row in sweep.legacy) {
    if (row.announcedBySweep) addConfigAdvisory(warns, row.replacement);
  }

  return result;
}

void _rejectRetiredTurnLimitKeys(Map<String, dynamic> yaml) {
  if (yaml.containsKey('worker_timeout')) {
    throw const FormatException(
      'Retired config key server.worker_timeout; use governance.turn_limits.turn_timeout instead.',
    );
  }
  final governance = yaml['governance'];
  if (governance is Map && governance.containsKey('turn_progress')) {
    final turnProgress = governance['turn_progress'];
    if (turnProgress is Map && turnProgress.containsKey('max_duration')) {
      throw const FormatException(
        'Retired config key governance.turn_progress.max_duration; use '
        'governance.turn_limits.turn_timeout instead.',
      );
    }
    throw const FormatException('Retired config key governance.turn_progress; use governance.turn_limits instead.');
  }
  final harness = yaml['harness'];
  if (harness is Map && harness.containsKey('turn_monitor')) {
    throw const FormatException(
      'Retired config key harness.turn_monitor; use governance.turn_limits.stall_timeout instead.',
    );
  }
}

String _loadedConfigBaseDir(Map<String, String> env, {String? configPath}) {
  if (configPath != null) {
    return p.dirname(p.normalize(p.absolute(expandHome(configPath, env: env))));
  }
  final envPath = env['DARTCLAW_CONFIG'];
  if (envPath != null) {
    return p.dirname(p.normalize(p.absolute(expandHome(envPath, env: env))));
  }
  final homeEnv = env['DARTCLAW_HOME'];
  if (homeEnv != null) {
    return p.normalize(p.absolute(expandHome(homeEnv, env: env)));
  }
  return p.normalize(p.absolute(p.join(env['HOME'] ?? env['USERPROFILE'] ?? '.', '.dartclaw')));
}

Map<String, dynamic>? _sectionMap(String key, Map<String, dynamic> yaml, List<String> warns) =>
    readMap(key, yaml, warns);

ServerConfig _parseTopLevel(
  Map<String, dynamic> yaml,
  Map<String, String> cli,
  Map<String, String> env,
  ServerConfig defaults,
  List<String> warns, {
  required String configBaseDir,
}) {
  final port = _parseInt('port', cli['port'], yaml['port'], defaults.port, warns);
  final host = _parseString('host', cli['host'], yaml['host'], defaults.host, env, warns);
  final name = _parseString('name', cli['name'], yaml['name'], defaults.name, env, warns);
  String? baseUrl = defaults.baseUrl;
  final rawBaseUrl = readString('base_url', yaml, warns);
  if (rawBaseUrl != null) {
    final normalized = envSubstitute(rawBaseUrl, env: env).trim();
    baseUrl = normalized.isEmpty ? null : normalized;
  }
  final defaultDataDir = env['DARTCLAW_HOME'] ?? defaults.dataDir;
  final rawCliDataDir = cli['data_dir'];
  final hasYamlDataDir = yaml.containsKey('data_dir') && yaml['data_dir'] != null;
  final rawDataDir = rawCliDataDir ?? _yamlString('data_dir', yaml['data_dir'], defaultDataDir, env, warns);
  final expandedDataDir = expandHome(rawDataDir, env: env);
  final dataDir = p.normalize(
    p.isAbsolute(expandedDataDir)
        ? expandedDataDir
        : rawCliDataDir != null || !hasYamlDataDir
        ? p.absolute(expandedDataDir)
        : p.absolute(p.join(configBaseDir, expandedDataDir)),
  );
  final claudeExecutable = expandHome(cli['claude_executable'] ?? defaults.claudeExecutable, env: env);
  final rawSourceDir = cli['source_dir'] ?? _yamlStringOrNull('source_dir', yaml['source_dir'], env, warns);
  final sourceDir = rawSourceDir != null ? expandHome(rawSourceDir, env: env) : null;
  final rawStaticDir = cli['static_dir'] ?? _yamlStringOrNull('static_dir', yaml['static_dir'], env, warns);
  final staticDir = expandHome(
    rawStaticDir ?? (sourceDir != null ? p.join(sourceDir, defaults.staticDir) : defaults.staticDir),
    env: env,
  );
  final rawTemplatesDir = cli['templates_dir'] ?? _yamlStringOrNull('templates_dir', yaml['templates_dir'], env, warns);
  final templatesDir = expandHome(
    rawTemplatesDir ?? (sourceDir != null ? p.join(sourceDir, defaults.templatesDir) : defaults.templatesDir),
    env: env,
  );

  final devMode = yaml['dev_mode'] == true || cli['dev_mode'] == 'true';
  final concurrencyMap = readMap('concurrency', yaml, warns);
  final maxParallelTurns =
      readInt('max_parallel_turns', concurrencyMap ?? {}, warns, defaultValue: defaults.maxParallelTurns) ??
      defaults.maxParallelTurns;

  return ServerConfig(
    port: port,
    host: host,
    name: name,
    dataDir: dataDir,
    baseUrl: baseUrl,
    claudeExecutable: claudeExecutable,
    staticDir: staticDir,
    templatesDir: templatesDir,
    devMode: devMode,
    maxParallelTurns: maxParallelTurns,
  );
}

LoggingConfig _parseLogging(
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

  final logMap = readMap('logging', yaml, warns);
  if (logMap != null) {
    if (cli['log_format'] == null && logMap['format'] is String) format = logMap['format'] as String;
    if (cli['log_file'] == null && logMap['file'] is String) {
      file = expandHome(envSubstitute(logMap['file'] as String, env: env), env: env);
    }
    if (cli['log_level'] == null && logMap['level'] is String) level = logMap['level'] as String;
    redactPatterns = readStringList('redact_patterns', logMap, warns, defaultValue: redactPatterns) ?? redactPatterns;
  }

  return LoggingConfig(format: format, file: file, level: level, redactPatterns: redactPatterns);
}

AgentConfig _parseAgent(Map<String, dynamic> yaml, AgentConfig defaults, List<String> warns) {
  var provider = defaults.provider;
  var disallowedTools = defaults.disallowedTools;
  int? maxTurns = defaults.maxTurns;
  String? model = defaults.model;
  String? effort = defaults.effort;
  ExecutionMode? execution = defaults.execution;

  final agentMap = _sectionMap('agent', yaml, warns);
  if (agentMap != null) {
    execution = AgentDefinition.parseExecutionMode(agentMap['execution'], 'agent.execution') ?? execution;
    disallowedTools =
        readStringList('disallowed_tools', agentMap, warns, defaultValue: disallowedTools) ?? disallowedTools;
    final providerVal = readString('provider', agentMap, warns);
    if (providerVal != null) {
      if (providerVal.trim().isEmpty) {
        throw const FormatException('agent.provider must not be empty.');
      }
      provider = ProviderIdentity.normalize(providerVal);
    }
    maxTurns = readInt('max_turns', agentMap, warns, defaultValue: maxTurns);
    final modelVal = readString('model', agentMap, warns);
    if (modelVal != null) {
      final shorthand = ProviderIdentity.parseProviderModelShorthand(modelVal);
      if (shorthand != null) {
        model = shorthand.model;
        if (providerVal == null) {
          provider = shorthand.provider;
        } else if (provider != shorthand.provider) {
          warns.add(
            'agent.model shorthand provider "${shorthand.provider}" conflicts with agent.provider '
            '"$provider" — using agent.provider',
          );
        }
      } else {
        model = modelVal;
      }
    }
    final effortVal = readString('effort', agentMap, warns);
    if (effortVal != null) effort = effortVal;
  }

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

  var historyConfig = const HistoryConfig.defaults();
  final historyMap = agentMap != null ? readMap('history', agentMap, warns) : null;
  if (historyMap != null) {
    var maxMessageChars = historyConfig.maxMessageChars;
    var maxTotalChars = historyConfig.maxTotalChars;

    final mmcRead = readInt('max_message_chars', historyMap, warns);
    if (mmcRead != null) {
      if (!ConfigNumericBounds.isOutOfRange('agent.history.max_message_chars', mmcRead, requireMin: true)) {
        maxMessageChars = mmcRead;
      } else {
        warns.add('Invalid agent.history.max_message_chars: $mmcRead (must be int >= 500) — using default');
      }
    }

    final mtcRead = readInt('max_total_chars', historyMap, warns);
    if (mtcRead != null) {
      if (!ConfigNumericBounds.isOutOfRange('agent.history.max_total_chars', mtcRead, requireMin: true)) {
        maxTotalChars = mtcRead;
      } else {
        warns.add('Invalid agent.history.max_total_chars: $mtcRead (must be int >= 5000) — using default');
      }
    }

    if (maxTotalChars < maxMessageChars) {
      warns.add(
        'agent.history.max_total_chars ($maxTotalChars) < max_message_chars ($maxMessageChars) — using defaults',
      );
      maxMessageChars = const HistoryConfig.defaults().maxMessageChars;
      maxTotalChars = const HistoryConfig.defaults().maxTotalChars;
    }

    historyConfig = HistoryConfig(maxMessageChars: maxMessageChars, maxTotalChars: maxTotalChars);
  }

  return AgentConfig(
    provider: provider,
    model: model,
    effort: effort,
    maxTurns: maxTurns,
    execution: execution,
    disallowedTools: disallowedTools,
    definitions: definitions,
    history: historyConfig,
  );
}

void _warnIfUnrecognizedModel(List<String> warns, String field, String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return;
  final lower = trimmed.toLowerCase();
  if (_recognizedClaudeModels.hasMatch(lower) || _recognizedCodexModels.contains(lower)) return;
  addConfigAdvisory(warns, 'Unrecognized $field: "$trimmed" — keeping value as configured');
}

AuthConfig _parseAuth(Map<String, dynamic> yaml, AuthConfig defaults, List<String> warns) {
  var cookieSecure = defaults.cookieSecure;
  var trustedProxies = defaults.trustedProxies;

  final authMap = _sectionMap('auth', yaml, warns);
  if (authMap != null) {
    cookieSecure = readBool('cookie_secure', authMap, warns, defaultValue: cookieSecure) ?? cookieSecure;
    trustedProxies = readStringList('trusted_proxies', authMap, warns, defaultValue: trustedProxies) ?? trustedProxies;
  }

  return AuthConfig(cookieSecure: cookieSecure, trustedProxies: trustedProxies);
}

GatewayConfig _parseGateway(
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
    final mode = readString('auth_mode', gMap, warns);
    if (mode != null) {
      final field = ConfigMeta.fields['gateway.auth_mode']!;
      if (FieldConstraints.evaluate(field, mode) == null) {
        authMode = mode;
      } else {
        warns.add('Invalid gateway.auth_mode: "$mode" — using default');
      }
    }
    final tokenVal = readString('token', gMap, warns);
    if (tokenVal != null && tokenVal.isNotEmpty) {
      // A `${VAR}` that envSubstitute could not resolve yields a blank value.
      // Keeping it would hand the gateway a credential an empty bearer header
      // satisfies, so drop it and let the generated token file take over.
      final resolved = envSubstitute(tokenVal, env: env);
      if (resolved.trim().isEmpty) {
        final refs = envReferences(tokenVal);
        final unresolved = refs.map((name) => '\${$name}').join(', ');
        warns.add(
          'gateway.token resolves to an empty value'
          '${refs.isEmpty ? '' : ' (unset $unresolved)'}'
          ' — ignoring it and using the generated token file instead',
        );
      } else {
        token = resolved;
      }
    }
    hsts = readBool('hsts', gMap, warns, defaultValue: hsts) ?? hsts;
  }

  final clients = _parseMcpClients(gMap, env, authMode: authMode, gatewayToken: token);
  final reload = _parseReloadConfig(gMap, defaults.reload, warns);
  return GatewayConfig(authMode: authMode, token: token, hsts: hsts, reload: reload, mcpClients: clients);
}

/// Parses `gateway.mcp_clients` into the named clients `/mcp` will authenticate.
///
/// Startup-fatal on every rule, because each one describes a client list the
/// route cannot enforce: a literal token cannot be rotated out of the config
/// file, an unresolved reference would authenticate the empty string
/// ([envSubstitute] resolves an undefined `${VAR}` to `''`), a shared or
/// gateway-equal token makes the audit principal a guess, and a client under
/// `auth_mode: none` claims a boundary on an unauthenticated instance.
List<McpClientConfig> _parseMcpClients(
  Map<String, dynamic>? gMap,
  Map<String, String> env, {
  required String authMode,
  required String? gatewayToken,
}) {
  final raw = gMap?['mcp_clients'];
  if (raw == null) return const [];
  if (raw is! List) {
    throw const FormatException('gateway.mcp_clients must be a list of {name, token} entries.');
  }
  if (raw.isEmpty) return const [];
  if (authMode != 'token') {
    throw FormatException(
      'gateway.mcp_clients requires gateway.auth_mode: token, but it is "$authMode". '
      'A named MCP client cannot be authenticated on an unauthenticated instance.',
    );
  }

  final clients = <McpClientConfig>[];
  final byName = <String>{};
  final byToken = <String, String>{};
  for (final (index, entry) in raw.indexed) {
    if (entry is! Map) {
      throw FormatException('gateway.mcp_clients[$index] must be a map with name and token.');
    }
    final fields = Map<String, dynamic>.from(entry);
    final name = (fields['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      throw FormatException('gateway.mcp_clients[$index]: name is required and must be a non-empty string.');
    }
    if (!byName.add(name)) {
      throw FormatException('gateway.mcp_clients: client "$name" is declared more than once.');
    }
    final reference = (fields['token'] as String?)?.trim() ?? '';
    if (reference.isEmpty) {
      throw FormatException('gateway.mcp_clients: client "$name" is missing a token.');
    }
    if (envReferences(reference).isEmpty) {
      throw FormatException(
        'gateway.mcp_clients: client "$name" must reference its token as \${VAR}, not carry a literal value.',
      );
    }
    final resolved = envSubstitute(reference, env: env);
    if (resolved.isEmpty) {
      throw FormatException(
        'gateway.mcp_clients: client "$name" token reference $reference resolves to nothing — '
        'set the environment variable, or remove the client.',
      );
    }
    if (gatewayToken != null && resolved == gatewayToken) {
      throw FormatException('gateway.mcp_clients: client "$name" token is the gateway token.');
    }
    final owner = byToken[resolved];
    if (owner != null) {
      throw FormatException('gateway.mcp_clients: clients "$owner" and "$name" share one token.');
    }
    byToken[resolved] = name;
    clients.add(McpClientConfig(name: name, tokenReference: reference, token: resolved));
  }
  return List.unmodifiable(clients);
}

ReloadConfig _parseReloadConfig(Map<dynamic, dynamic>? gMap, ReloadConfig defaults, List<String> warns) {
  if (gMap == null) return defaults;
  final rMap = readMap('reload', gMap, warns);
  if (rMap == null) return defaults;

  var mode = defaults.mode;
  var debounceMs = defaults.debounceMs;

  final modeVal = readString('mode', rMap, warns);
  if (modeVal != null) {
    final field = ConfigMeta.fields['gateway.reload.mode']!;
    if (FieldConstraints.evaluate(field, modeVal) == null) {
      mode = modeVal;
    } else {
      warns.add('Invalid gateway.reload.mode: "$modeVal" — using default "${defaults.mode}"');
    }
  }

  final debounceVal = readInt('debounce_ms', rMap, warns);
  if (debounceVal != null) {
    if (!ConfigNumericBounds.isOutOfRange('gateway.reload.debounce_ms', debounceVal, requireMin: true)) {
      debounceMs = debounceVal;
    } else {
      warns.add('gateway.reload.debounce_ms must be >= 100, got $debounceVal — using default ${defaults.debounceMs}');
    }
  }

  return ReloadConfig(mode: mode, debounceMs: debounceMs);
}

SessionConfig _parseSessions(Map<String, dynamic> yaml, SessionConfig defaults, List<String> warns) {
  var resetHour = defaults.resetHour;
  var idleTimeoutMinutes = defaults.idleTimeoutMinutes;
  var scopeConfig = defaults.scopeConfig;
  var maintenanceConfig = defaults.maintenanceConfig;

  final sessionsMap = _sectionMap('sessions', yaml, warns);
  if (sessionsMap != null) {
    resetHour = readInt('reset_hour', sessionsMap, warns, defaultValue: defaults.resetHour) ?? defaults.resetHour;
    idleTimeoutMinutes =
        readInt('idle_timeout_minutes', sessionsMap, warns, defaultValue: defaults.idleTimeoutMinutes) ??
        defaults.idleTimeoutMinutes;
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

SessionScopeConfig _parseSessionScope(
  Map<dynamic, dynamic> sessionsRaw,
  SessionScopeConfig defaultScope,
  List<String> warns,
) {
  var dmScope = defaultScope.dmScope;
  final dmScopeRaw = readString('dm_scope', sessionsRaw, warns);
  if (dmScopeRaw != null) {
    final parsed = DmScope.fromYaml(dmScopeRaw);
    if (parsed != null) {
      dmScope = parsed;
    } else {
      warns.add('Invalid value for sessions.dm_scope: "$dmScopeRaw" — using default');
    }
  }

  var groupScope = defaultScope.groupScope;
  final groupScopeRaw = readString('group_scope', sessionsRaw, warns);
  if (groupScopeRaw != null) {
    final parsed = GroupScope.fromYaml(groupScopeRaw);
    if (parsed != null) {
      groupScope = parsed;
    } else {
      warns.add('Invalid value for sessions.group_scope: "$groupScopeRaw" — using default');
    }
  }

  var model = defaultScope.model;
  final modelRaw = readString('model', sessionsRaw, warns);
  if (modelRaw != null) {
    model = modelRaw;
    _warnIfUnrecognizedModel(warns, 'sessions.model', model);
  }

  var effort = defaultScope.effort;
  final effortVal2 = readString('effort', sessionsRaw, warns);
  if (effortVal2 != null) effort = effortVal2;

  final channelOverrides = <String, ChannelScopeConfig>{};
  final channelsMap = readMap('channels', sessionsRaw, warns);
  if (channelsMap != null) {
    for (final MapEntry(:key, :value) in channelsMap.entries) {
      if (value is! Map) {
        // reason: dynamic key interpolation — per-channel warn can't use readX helpers
        warns.add('Invalid type for sessions.channels.$key: "${value.runtimeType}" — skipping');
        continue;
      }
      final chMap = Map<String, dynamic>.from(value);
      final chDmRaw = chMap['dm_scope'];
      final chDmScope = chDmRaw is String ? DmScope.fromYaml(chDmRaw) : null;
      if (chDmRaw is String && chDmScope == null) {
        warns.add('Invalid value for sessions.channels.$key.dm_scope: "$chDmRaw" — ignoring');
      }
      final chGroupRaw = chMap['group_scope'];
      final chGroupScope = chGroupRaw is String ? GroupScope.fromYaml(chGroupRaw) : null;
      if (chGroupRaw is String && chGroupScope == null) {
        warns.add('Invalid value for sessions.channels.$key.group_scope: "$chGroupRaw" — ignoring');
      }
      final chModel = chMap['model'] is String ? chMap['model'] as String : null;
      if (chModel != null) _warnIfUnrecognizedModel(warns, 'sessions.channels.$key.model', chModel);
      final chEffort = chMap['effort'] is String ? chMap['effort'] as String : null;
      if (chDmScope != null || chGroupScope != null || chModel != null || chEffort != null) {
        channelOverrides[key] = ChannelScopeConfig(
          dmScope: chDmScope,
          groupScope: chGroupScope,
          model: chModel,
          effort: chEffort,
        );
      }
    }
  }

  return SessionScopeConfig(
    dmScope: dmScope,
    groupScope: groupScope,
    channels: channelOverrides,
    model: model,
    effort: effort,
  );
}

SessionMaintenanceConfig _parseSessionMaintenance(
  Map<dynamic, dynamic> sessionsRaw,
  SessionMaintenanceConfig defaultMaint,
  List<String> warns,
) {
  final maintMap = readMap('maintenance', sessionsRaw, warns);
  if (maintMap == null) return defaultMaint;

  var mode = defaultMaint.mode;
  final modeRaw = readString('mode', maintMap, warns);
  if (modeRaw != null) {
    final field = ConfigMeta.fields['sessions.maintenance.mode']!;
    if (FieldConstraints.evaluate(field, modeRaw) == null) {
      mode = MaintenanceMode.fromYaml(modeRaw)!;
    } else {
      warns.add('Invalid value for sessions.maintenance.mode: "$modeRaw" — using default');
    }
  }

  final pruneAfterDays =
      readInt('prune_after_days', maintMap, warns, defaultValue: defaultMaint.pruneAfterDays) ??
      defaultMaint.pruneAfterDays;
  final maxSessions =
      readInt('max_sessions', maintMap, warns, defaultValue: defaultMaint.maxSessions) ?? defaultMaint.maxSessions;
  final maxDiskMb =
      readInt('max_disk_mb', maintMap, warns, defaultValue: defaultMaint.maxDiskMb) ?? defaultMaint.maxDiskMb;
  final cronRetentionHours =
      readInt('cron_retention_hours', maintMap, warns, defaultValue: defaultMaint.cronRetentionHours) ??
      defaultMaint.cronRetentionHours;

  var schedule = defaultMaint.schedule;
  final schedRaw = readString('schedule', maintMap, warns);
  if (schedRaw != null && schedRaw.isNotEmpty) schedule = schedRaw;

  return SessionMaintenanceConfig(
    mode: mode,
    pruneAfterDays: pruneAfterDays,
    maxSessions: maxSessions,
    maxDiskMb: maxDiskMb,
    cronRetentionHours: cronRetentionHours,
    schedule: schedule,
  );
}

ContextConfig _parseContext(Map<String, dynamic> yaml, ContextConfig defaults, List<String> warns) {
  var reserveTokens = defaults.reserveTokens;
  var maxResultBytes = defaults.maxResultBytes;
  var warningThreshold = defaults.warningThreshold;
  String? compactInstructions = defaults.compactInstructions;
  var identifierPreservation = defaults.identifierPreservation;
  String? identifierInstructions = defaults.identifierInstructions;

  final contextMap = _sectionMap('context', yaml, warns);
  if (contextMap != null) {
    reserveTokens =
        readInt('reserve_tokens', contextMap, warns, defaultValue: defaults.reserveTokens) ?? defaults.reserveTokens;
    maxResultBytes =
        readInt('max_result_bytes', contextMap, warns, defaultValue: defaults.maxResultBytes) ??
        defaults.maxResultBytes;
    warningThreshold = ConfigNumericBounds.clamp(
      'context.warning_threshold',
      readInt('warning_threshold', contextMap, warns, defaultValue: defaults.warningThreshold) ??
          defaults.warningThreshold,
    );
    final ciRaw = readString('compact_instructions', contextMap, warns);
    if (ciRaw != null && ciRaw.trim().isNotEmpty) compactInstructions = ciRaw;

    final ipRaw = readString('identifier_preservation', contextMap, warns);
    if (ipRaw != null) {
      final field = ConfigMeta.fields['context.identifier_preservation']!;
      if (FieldConstraints.evaluate(field, ipRaw) == null) {
        identifierPreservation = IdentifierPreservationMode.fromJsonString(ipRaw);
      } else {
        warns.add(
          'Invalid value for context.identifier_preservation: "$ipRaw" — '
          'expected one of ${field.allowedValues!.join(', ')}; using default "strict"',
        );
      }
    }

    final iiRaw = readString('identifier_instructions', contextMap, warns);
    if (iiRaw != null && iiRaw.trim().isNotEmpty) identifierInstructions = iiRaw;
  }

  return ContextConfig(
    reserveTokens: reserveTokens,
    maxResultBytes: maxResultBytes,
    warningThreshold: warningThreshold,
    compactInstructions: compactInstructions,
    identifierPreservation: identifierPreservation,
    identifierInstructions: identifierInstructions,
  );
}

WorkspaceConfig _parseWorkspace(Map<String, dynamic> yaml, WorkspaceConfig defaults, List<String> warns) {
  var gitSyncEnabled = defaults.gitSyncEnabled;
  var gitSyncPushEnabled = defaults.gitSyncPushEnabled;
  var gitSyncIntervalMinutes = defaults.gitSyncIntervalMinutes;

  final workspaceMap = _sectionMap('workspace', yaml, warns);
  if (workspaceMap != null) {
    final gsMap = readMap('git_sync', workspaceMap, warns);
    if (gsMap != null) {
      gitSyncEnabled = readBool('enabled', gsMap, warns, defaultValue: gitSyncEnabled) ?? gitSyncEnabled;
      gitSyncPushEnabled =
          readBool('push_enabled', gsMap, warns, defaultValue: gitSyncPushEnabled) ?? gitSyncPushEnabled;
      gitSyncIntervalMinutes =
          readInt('interval_minutes', gsMap, warns, defaultValue: gitSyncIntervalMinutes) ?? gitSyncIntervalMinutes;
    }
  }

  return WorkspaceConfig(
    gitSyncEnabled: gitSyncEnabled,
    gitSyncPushEnabled: gitSyncPushEnabled,
    gitSyncIntervalMinutes: gitSyncIntervalMinutes,
  );
}

OnboardingConfig _parseOnboarding(Map<String, dynamic> yaml, OnboardingConfig defaults, List<String> warns) {
  var expiryDays = defaults.expiryDays;

  final onboardingMap = _sectionMap('onboarding', yaml, warns);
  if (onboardingMap != null) {
    expiryDays = readInt('expiry_days', onboardingMap, warns, defaultValue: expiryDays) ?? expiryDays;
    if (ConfigNumericBounds.isOutOfRange('onboarding.expiry_days', expiryDays, requireMin: true)) {
      warns.add('Invalid onboarding.expiry_days: "$expiryDays" — using default ${defaults.expiryDays}');
      expiryDays = defaults.expiryDays;
    }
  }

  return OnboardingConfig(expiryDays: expiryDays);
}

SchedulingConfig _parseScheduling(Map<String, dynamic> yaml, SchedulingConfig defaults, List<String> warns) {
  var jobs = <Map<String, dynamic>>[];
  var heartbeatEnabled = defaults.heartbeatEnabled;
  var heartbeatIntervalMinutes = defaults.heartbeatIntervalMinutes;

  final schedulingMap = _sectionMap('scheduling', yaml, warns);
  if (schedulingMap != null) {
    final jobsList = readField<List<dynamic>>('jobs', schedulingMap, warns);
    if (jobsList != null) {
      for (final entry in jobsList) {
        if (entry is Map) {
          jobs.add(Map<String, dynamic>.from(entry));
        } else {
          warns.add('Invalid scheduling job entry: "${entry.runtimeType}" — skipping');
        }
      }
    }

    final hbMap = readMap('heartbeat', schedulingMap, warns);
    if (hbMap != null) {
      heartbeatEnabled = readBool('enabled', hbMap, warns, defaultValue: heartbeatEnabled) ?? heartbeatEnabled;
      heartbeatIntervalMinutes =
          readInt('interval_minutes', hbMap, warns, defaultValue: defaults.heartbeatIntervalMinutes) ??
          defaults.heartbeatIntervalMinutes;
    }
  }

  final taskDefs = <ScheduledTaskDefinition>[];
  for (final jobMap in jobs) {
    final typeStr = jobMap['type'] as String?;
    if (typeStr == 'task') {
      final taskRaw = jobMap['task'];
      if (taskRaw is! Map) {
        warns.add('Scheduling job "${jobMap['id'] ?? jobMap['name']}" (type: task) missing "task" section — skipping');
        continue;
      }
      final id = (jobMap['id'] ?? jobMap['name']) as String? ?? '';
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

UsageConfig _parseUsage(Map<String, dynamic> yaml, UsageConfig defaults, List<String> warns) {
  int? budgetWarningTokens = defaults.budgetWarningTokens;
  var maxFileSizeBytes = defaults.maxFileSizeBytes;

  final usageMap = _sectionMap('usage', yaml, warns);
  if (usageMap != null) {
    budgetWarningTokens = readInt('budget_warning_tokens', usageMap, warns, defaultValue: budgetWarningTokens);
    maxFileSizeBytes =
        readInt('max_file_size_bytes', usageMap, warns, defaultValue: defaults.maxFileSizeBytes) ??
        defaults.maxFileSizeBytes;
  }

  return UsageConfig(budgetWarningTokens: budgetWarningTokens, maxFileSizeBytes: maxFileSizeBytes);
}

MemoryConfig _parseMemory(
  Map<String, dynamic> yaml,
  Map<String, String> cli,
  MemoryConfig defaults,
  List<String> warns,
) {
  var maxBytes = defaults.maxBytes;
  var pruningEnabled = defaults.pruningEnabled;
  var archiveAfterDays = defaults.archiveAfterDays;
  var pruningSchedule = defaults.pruningSchedule;
  var journalEnabled = defaults.journalEnabled;
  var journalSchedule = defaults.journalSchedule;
  var curationEnabled = defaults.curationEnabled;
  var curationSchedule = defaults.curationSchedule;

  final memoryMap = _sectionMap('memory', yaml, warns);
  final nestedMaxBytes = memoryMap?['max_bytes'];
  final pruningRaw = memoryMap?['pruning'];
  final journalRaw = memoryMap?['journal'];
  final curationRaw = memoryMap?['curation'];

  final legacyTopLevelMaxBytes = yaml['memory_max_bytes'];
  if (legacyTopLevelMaxBytes != null && nestedMaxBytes == null) {
    addConfigAdvisory(warns, 'Config key "memory_max_bytes" is deprecated; use "memory.max_bytes" instead');
  }

  if (nestedMaxBytes != null) {
    maxBytes = _parsePositiveInt('memory.max_bytes', cli['memory_max_bytes'], nestedMaxBytes, defaults.maxBytes);
  } else {
    maxBytes = _parsePositiveInt(
      'memory.max_bytes',
      cli['memory_max_bytes'],
      legacyTopLevelMaxBytes,
      defaults.maxBytes,
    );
  }

  final pruningMap = pruningRaw is Map ? pruningRaw : null;
  pruningEnabled = _parseBool(
    'memory.pruning.enabled',
    cli['memory_pruning_enabled'],
    pruningMap?['enabled'],
    pruningEnabled,
    warns,
  );
  archiveAfterDays = _parsePositiveInt(
    'memory.pruning.archive_after_days',
    cli['memory_pruning_archive_after_days'],
    pruningMap?['archive_after_days'],
    defaults.archiveAfterDays,
  );
  if (cli['memory_pruning_schedule'] case final cliSchedule?) {
    pruningSchedule = cliSchedule;
  } else if (pruningMap?['schedule'] is String) {
    pruningSchedule = pruningMap!['schedule'] as String;
  }

  final journalMap = journalRaw is Map ? journalRaw : null;
  if (memoryMap?.containsKey('journal') ?? false) {
    if (journalMap == null) {
      throw const FormatException('memory.journal must be a map.');
    }
    if (journalMap.containsKey('schedule') && journalMap['schedule'] is! String) {
      throw const FormatException('memory.journal.schedule must be a string.');
    }
  }
  journalEnabled = _parseBool(
    'memory.journal.enabled',
    cli['memory_journal_enabled'],
    journalMap?['enabled'],
    journalEnabled,
    warns,
  );
  if (cli['memory_journal_schedule'] case final cliSchedule?) {
    journalSchedule = cliSchedule;
  } else if (journalMap?['schedule'] is String) {
    journalSchedule = journalMap!['schedule'] as String;
  }

  final curationMap = curationRaw is Map ? curationRaw : null;
  if (memoryMap?.containsKey('curation') ?? false) {
    if (curationMap == null) {
      throw const FormatException('memory.curation must be a map.');
    }
    if (curationMap.containsKey('schedule') && curationMap['schedule'] is! String) {
      throw const FormatException('memory.curation.schedule must be a string.');
    }
  }
  curationEnabled = _parseBool(
    'memory.curation.enabled',
    cli['memory_curation_enabled'],
    curationMap?['enabled'],
    curationEnabled,
    warns,
  );
  if (cli['memory_curation_schedule'] case final cliSchedule?) {
    curationSchedule = cliSchedule;
  } else if (curationMap?['schedule'] is String) {
    curationSchedule = curationMap!['schedule'] as String;
  }

  return MemoryConfig(
    maxBytes: maxBytes,
    pruningEnabled: pruningEnabled,
    archiveAfterDays: archiveAfterDays,
    pruningSchedule: pruningSchedule,
    journalEnabled: journalEnabled,
    journalSchedule: journalSchedule,
    curationEnabled: curationEnabled,
    curationSchedule: curationSchedule,
  );
}

KnowledgeConfig _parseKnowledge(Map<String, dynamic> yaml, KnowledgeConfig defaults, List<String> warns) {
  final knowledgeMap = _sectionMap('knowledge', yaml, warns);
  if (knowledgeMap == null) return defaults;

  var inbox = defaults.inbox;
  final inboxMap = readMap('inbox', knowledgeMap, warns);
  if (inboxMap != null) {
    inbox = KnowledgeInboxConfig(
      enabled: readBool('enabled', inboxMap, warns, defaultValue: inbox.enabled) ?? inbox.enabled,
      intervalMinutes: ConfigNumericBounds.clamp(
        'knowledge.inbox.interval_minutes',
        readInt('interval_minutes', inboxMap, warns, defaultValue: inbox.intervalMinutes) ?? inbox.intervalMinutes,
      ).toInt(),
      maxBytes: ConfigNumericBounds.clamp(
        'knowledge.inbox.max_bytes',
        readInt('max_bytes', inboxMap, warns, defaultValue: inbox.maxBytes) ?? inbox.maxBytes,
      ).toInt(),
      retryAttempts: ConfigNumericBounds.clamp(
        'knowledge.inbox.retry_attempts',
        readInt('retry_attempts', inboxMap, warns, defaultValue: inbox.retryAttempts) ?? inbox.retryAttempts,
      ).toInt(),
      processedRetentionDays: ConfigNumericBounds.clamp(
        'knowledge.inbox.processed_retention_days',
        readInt('processed_retention_days', inboxMap, warns, defaultValue: inbox.processedRetentionDays) ??
            inbox.processedRetentionDays,
      ).toInt(),
      deliveryMode: _knowledgeDeliveryMode(inboxMap['delivery_mode'], inbox.deliveryMode, 'knowledge.inbox', warns),
      effort: _knowledgeEffort(readString('effort', inboxMap, warns), inbox.effort),
    );
  }

  var wikiLint = defaults.wikiLint;
  final wikiLintMap = readMap('wiki_lint', knowledgeMap, warns);
  if (wikiLintMap != null) {
    wikiLint = KnowledgeWikiLintConfig(
      enabled: readBool('enabled', wikiLintMap, warns, defaultValue: wikiLint.enabled) ?? wikiLint.enabled,
      intervalMinutes: ConfigNumericBounds.clamp(
        'knowledge.wiki_lint.interval_minutes',
        readInt('interval_minutes', wikiLintMap, warns, defaultValue: wikiLint.intervalMinutes) ??
            wikiLint.intervalMinutes,
      ).toInt(),
      deliveryMode: _knowledgeDeliveryMode(
        wikiLintMap['delivery_mode'],
        wikiLint.deliveryMode,
        'knowledge.wiki_lint',
        warns,
      ),
    );
  }

  return KnowledgeConfig(inbox: inbox, wikiLint: wikiLint);
}

String _knowledgeEffort(String? raw, String fallback) {
  final effort = raw?.trim();
  return effort == null || effort.isEmpty ? fallback : effort;
}

String _knowledgeDeliveryMode(Object? raw, String fallback, String path, List<String> warns) {
  if (raw == null) return fallback;
  if (raw is! String) {
    warns.add('Invalid type for $path.delivery_mode: "${raw.runtimeType}" — using default');
    return fallback;
  }
  final value = raw.trim();
  if (value == 'none' || value == 'announce' || value == 'webhook') return value;
  warns.add('Invalid $path.delivery_mode: "$raw" — using default');
  return fallback;
}

ContainerConfig _parseContainer(Map<String, dynamic> yaml, List<String> warns) {
  final containerMap = readMap('container', yaml, warns);
  return containerMap != null ? ContainerConfig.fromYaml(containerMap, warns) : const ContainerConfig();
}

ChannelConfig _parseChannels(Map<String, dynamic> yaml, List<String> warns) {
  final channelsMap = readMap('channels', yaml, warns);
  return channelsMap != null ? ChannelConfig.fromYaml(channelsMap, warns) : const ChannelConfig.defaults();
}

TaskConfig _parseTasks(Map<String, dynamic> yaml, TaskConfig defaults, List<String> warns) {
  var artifactRetentionDays = defaults.artifactRetentionDays;
  var completionAction = defaults.completionAction;
  var worktreeBaseRef = defaults.worktreeBaseRef;
  var worktreeStaleTimeoutHours = defaults.worktreeStaleTimeoutHours;
  var worktreeMergeStrategy = defaults.worktreeMergeStrategy;

  final tasksMap = _sectionMap('tasks', yaml, warns);
  if (tasksMap != null) {
    artifactRetentionDays = ConfigNumericBounds.clamp(
      'tasks.artifact_retention_days',
      readInt('artifact_retention_days', tasksMap, warns, defaultValue: defaults.artifactRetentionDays) ??
          defaults.artifactRetentionDays,
    );
    final completionActionRaw = readString('completion_action', tasksMap, warns);
    if (completionActionRaw != null) {
      final trimmedCompletionAction = completionActionRaw.trim();
      if (trimmedCompletionAction == 'review' || trimmedCompletionAction == 'accept') {
        completionAction = trimmedCompletionAction;
      } else {
        warns.add(
          'Invalid value for tasks.completion_action: "$completionActionRaw" — using default '
          '"${defaults.completionAction}"',
        );
      }
    }

    final worktreeMap = readMap('worktree', tasksMap, warns);
    if (worktreeMap != null) {
      final br = worktreeMap['base_ref'];
      if (br is String && br.isNotEmpty) worktreeBaseRef = br;
      worktreeStaleTimeoutHours = ConfigNumericBounds.clamp(
        'tasks.worktree.stale_timeout_hours',
        readInt('stale_timeout_hours', worktreeMap, warns, defaultValue: defaults.worktreeStaleTimeoutHours) ??
            defaults.worktreeStaleTimeoutHours,
      );
      final ms = worktreeMap['merge_strategy'];
      if (ms is String) {
        final field = ConfigMeta.fields['tasks.worktree.merge_strategy']!;
        final trimmed = ms.trim();
        if (FieldConstraints.evaluate(field, trimmed) == null) {
          worktreeMergeStrategy = trimmed;
        } else {
          warns.add('Invalid value for tasks.worktree.merge_strategy: "$ms" — using default "squash"');
        }
      }
    }
  }

  var budget = defaults.budget;
  final budgetMap = tasksMap != null ? readMap('budget', tasksMap, warns) : null;
  if (budgetMap != null) {
    final defaultMaxTokens = readInt('default_max_tokens', budgetMap, warns, defaultValue: -1) ?? -1;
    final warningThresholdRaw = budgetMap['warning_threshold'];
    var warningThreshold = defaults.budget.warningThreshold;
    if (warningThresholdRaw != null) {
      final parsed = switch (warningThresholdRaw) {
        final double d => d,
        final int i => i.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };
      if (parsed != null && parsed >= 0.0 && parsed <= 1.0) {
        warningThreshold = parsed;
      } else {
        warns.add(
          'Invalid value for tasks.budget.warning_threshold: "$warningThresholdRaw" — using default '
          '"${defaults.budget.warningThreshold}"',
        );
      }
    }
    budget = TaskBudgetConfig(
      defaultMaxTokens: defaultMaxTokens > 0 ? defaultMaxTokens : null,
      warningThreshold: warningThreshold,
    );
  }

  return TaskConfig(
    artifactRetentionDays: artifactRetentionDays,
    completionAction: completionAction,
    worktreeBaseRef: worktreeBaseRef,
    worktreeStaleTimeoutHours: worktreeStaleTimeoutHours,
    worktreeMergeStrategy: worktreeMergeStrategy,
    budget: budget,
    execution: _parseTaskExecution(tasksMap, defaults.execution),
  );
}

/// Rejects explicit `container` execution selections that no enabled container
/// runtime can satisfy.
///
/// Cross-section, so it runs after every section is parsed. Startup-fatal:
/// substituting host execution for an unsatisfiable container request is
/// forbidden. Evaluated against the posture in force, which is why an unset
/// `container.enabled` defers this to the startup resolution step instead.
void validateExecutionPolicySelections(DartclawConfig config) {
  if (config.container.enabled) return;
  const remediation =
      'Set container.enabled: true or select execution: host. '
      'Container execution is never silently replaced by host execution.';
  void reject(String yamlPath) {
    throw FormatException(
      '$yamlPath: container requires container.enabled: true, but containers are disabled. '
      '$remediation',
    );
  }

  if (config.agent.execution == ExecutionMode.container) reject('agent.execution');
  for (final definition in config.agent.definitions) {
    if (definition.execution == ExecutionMode.container) reject('agent.agents.${definition.id}.execution');
  }
  if (config.tasks.execution == ExecutionMode.container) reject('tasks.execution');
}

/// Parses the single `tasks.execution` background-task execution mode.
///
/// The retired per-category map is startup-fatal because `research` previously
/// carried a narrower profile that cannot be widened silently.
ExecutionMode? _parseTaskExecution(Map<String, dynamic>? tasksMap, ExecutionMode? defaults) {
  if (tasksMap == null) return defaults;
  final rawExecution = tasksMap['execution'];
  if (rawExecution == null) return defaults;
  if (rawExecution is Map) {
    throw FormatException(
      'The per-category tasks.execution.<task-type> shape is retired. '
      'Set the single tasks.execution key to host or container, and declare a task securityProfile explicitly '
      'through the authenticated task API when a non-default container profile is required.',
    );
  }
  return AgentDefinition.parseExecutionMode(rawExecution, 'tasks.execution');
}

FeaturesConfig _parseFeatures(Map<String, dynamic> yaml) {
  final raw = yaml['features'];
  if (raw is Map) {
    return FeaturesConfig.fromYaml(Map<String, dynamic>.from(raw));
  }
  return const FeaturesConfig();
}

void _warnRetiredAndthenConfig(Map<String, dynamic> yaml, List<String> warns) {
  final atMap = _sectionMap('andthen', yaml, warns);
  if (atMap == null) return;

  for (final key in atMap.keys) {
    addConfigAdvisory(warns, 'Ignoring retired andthen.$key config; DartClaw no longer provisions AndThen skills.');
  }
}

void _warnRemovedAgentOrchestrationConfig(Map<String, dynamic> yaml, List<String> warns) {
  if (yaml.containsKey('delegation')) {
    addConfigAdvisory(
      warns,
      'Ignoring removed delegation config; define logical agents under agent.agents and use sessions_spawn.',
    );
  }
  final tasks = yaml['tasks'];
  if (tasks is Map && tasks.containsKey('max_concurrent')) {
    addConfigAdvisory(
      warns,
      'Ignoring removed tasks.max_concurrent; configure shared worker capacity with providers.<id>.pool_size.',
    );
  }
}
