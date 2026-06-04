part of 'dartclaw_config.dart';

const _validAdvisorTriggers = <String>{'turn_depth', 'token_velocity', 'periodic', 'task_review', 'explicit'};
final _recognizedClaudeModels = RegExp(
  r'^(default|haiku|sonnet|opus|opusplan)(\[[^\]]+\])?$|^(claude-[a-z0-9][a-z0-9.\-]*|anthropic\.claude-[a-z0-9.\-]+(@[a-z0-9.\-]+)?)$',
  caseSensitive: false,
);
const _recognizedCodexModels = <String>{
  'gpt-5.4',
  'gpt-5.4-mini',
  'gpt-5.4-nano',
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
  'onboarding',
  'workflow',
  'search',
  'usage',
  'guard_audit',
  'memory',
  'knowledge',
  'tasks',
  'canvas',
  'automation',
  'governance',
  'features',
  'projects',
  'advisor',
  'alerts',
  'security',
  'andthen',
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
        warns.add(
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
  final workerTimeout = _parseInt(
    'worker_timeout',
    cli['worker_timeout'],
    yaml['worker_timeout'],
    defaults.workerTimeout,
    warns,
  );

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
    workerTimeout: workerTimeout,
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

  final agentMap = _sectionMap('agent', yaml, warns);
  if (agentMap != null) {
    disallowedTools =
        readStringList('disallowed_tools', agentMap, warns, defaultValue: disallowedTools) ?? disallowedTools;
    final providerVal = readString('provider', agentMap, warns);
    if (providerVal != null) provider = providerVal;
    maxTurns = readInt('max_turns', agentMap, warns, defaultValue: maxTurns);
    final modelVal = readString('model', agentMap, warns);
    if (modelVal != null) {
      final shorthand = ProviderIdentity.parseProviderModelShorthand(modelVal);
      if (shorthand != null) {
        model = shorthand.model;
        if (providerVal == null) {
          provider = shorthand.provider;
        } else if (ProviderIdentity.normalize(provider) != shorthand.provider) {
          warns.add(
            'agent.model shorthand provider "${shorthand.provider}" conflicts with agent.provider '
            '"${ProviderIdentity.normalize(provider)}" — using agent.provider',
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
      if (mmcRead >= 500) {
        maxMessageChars = mmcRead;
      } else {
        warns.add('Invalid agent.history.max_message_chars: $mmcRead (must be int >= 500) — using default');
      }
    }

    final mtcRead = readInt('max_total_chars', historyMap, warns);
    if (mtcRead != null) {
      if (mtcRead >= 5000) {
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
  warns.add('Unrecognized $field: "$trimmed" — keeping value as configured');
}

AdvisorConfig _parseAdvisor(Map<String, dynamic> yaml, AdvisorConfig defaults, List<String> warns) {
  final advisorMap = _sectionMap('advisor', yaml, warns);
  if (advisorMap == null) return defaults;

  var enabled = readBool('enabled', advisorMap, warns, defaultValue: defaults.enabled) ?? defaults.enabled;

  String? model = defaults.model;
  final modelRaw = readString('model', advisorMap, warns);
  if (modelRaw != null) {
    final trimmed = modelRaw.trim();
    model = trimmed.isEmpty ? null : trimmed;
    _warnIfUnrecognizedModel(warns, 'advisor.model', model);
  }

  String? effort = defaults.effort;
  final effortRaw = readString('effort', advisorMap, warns);
  if (effortRaw != null) {
    final trimmed = effortRaw.trim();
    effort = trimmed.isEmpty ? null : trimmed;
  }

  var triggers = defaults.triggers;
  final triggersList = readField<List<dynamic>>('triggers', advisorMap, warns);
  if (triggersList != null) {
    final parsed = <String>[];
    for (final value in triggersList) {
      if (value is! String) {
        warns.add('Invalid advisor trigger type: "${value.runtimeType}" — skipping');
        continue;
      }
      final trigger = value.trim();
      if (trigger.isEmpty) continue;
      if (!_validAdvisorTriggers.contains(trigger)) {
        warns.add('Unknown advisor trigger: "$trigger" — skipping');
        continue;
      }
      parsed.add(trigger);
    }
    triggers = parsed;
  }

  final periodicIntervalMinutes =
      readInt('periodic_interval_minutes', advisorMap, warns, defaultValue: defaults.periodicIntervalMinutes) ??
      defaults.periodicIntervalMinutes;
  final maxWindowTurns =
      readInt('max_window_turns', advisorMap, warns, defaultValue: defaults.maxWindowTurns) ?? defaults.maxWindowTurns;
  final maxPriorReflections =
      readInt('max_prior_reflections', advisorMap, warns, defaultValue: defaults.maxPriorReflections) ??
      defaults.maxPriorReflections;

  return AdvisorConfig(
    enabled: enabled,
    model: model,
    effort: effort,
    triggers: triggers,
    periodicIntervalMinutes: periodicIntervalMinutes,
    maxWindowTurns: maxWindowTurns,
    maxPriorReflections: maxPriorReflections,
  );
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
      if (mode == 'token' || mode == 'none') {
        authMode = mode;
      } else {
        warns.add('Invalid gateway.auth_mode: "$mode" — using default');
      }
    }
    final tokenVal = readString('token', gMap, warns);
    if (tokenVal != null && tokenVal.isNotEmpty) {
      token = envSubstitute(tokenVal, env: env);
    }
    hsts = readBool('hsts', gMap, warns, defaultValue: hsts) ?? hsts;
  }

  final reload = _parseReloadConfig(gMap, defaults.reload, warns);
  return GatewayConfig(authMode: authMode, token: token, hsts: hsts, reload: reload);
}

ReloadConfig _parseReloadConfig(Map<dynamic, dynamic>? gMap, ReloadConfig defaults, List<String> warns) {
  if (gMap == null) return defaults;
  final rMap = readMap('reload', gMap, warns);
  if (rMap == null) return defaults;

  var mode = defaults.mode;
  var debounceMs = defaults.debounceMs;

  final modeVal = readString('mode', rMap, warns);
  if (modeVal != null) {
    if (modeVal == 'off' || modeVal == 'signal' || modeVal == 'auto') {
      mode = modeVal;
    } else {
      warns.add('Invalid gateway.reload.mode: "$modeVal" — using default "${defaults.mode}"');
    }
  }

  final debounceVal = readInt('debounce_ms', rMap, warns);
  if (debounceVal != null) {
    if (debounceVal >= 100) {
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
    final parsed = MaintenanceMode.fromYaml(modeRaw);
    if (parsed != null) {
      mode = parsed;
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
  var explorationSummaryThreshold = defaults.explorationSummaryThreshold;
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
    warningThreshold =
        (readInt('warning_threshold', contextMap, warns, defaultValue: defaults.warningThreshold) ??
                defaults.warningThreshold)
            .clamp(50, 99);
    explorationSummaryThreshold =
        (readInt(
                  'exploration_summary_threshold',
                  contextMap,
                  warns,
                  defaultValue: defaults.explorationSummaryThreshold,
                ) ??
                defaults.explorationSummaryThreshold)
            .clamp(1000, 1000000);
    final ciRaw = readString('compact_instructions', contextMap, warns);
    if (ciRaw != null && ciRaw.trim().isNotEmpty) compactInstructions = ciRaw;

    final ipRaw = readString('identifier_preservation', contextMap, warns);
    if (ipRaw != null) {
      try {
        identifierPreservation = IdentifierPreservationMode.fromJsonString(ipRaw);
      } on FormatException {
        warns.add(
          'Invalid value for context.identifier_preservation: "$ipRaw" — '
          'expected one of strict, off, custom; using default "strict"',
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
    explorationSummaryThreshold: explorationSummaryThreshold,
    compactInstructions: compactInstructions,
    identifierPreservation: identifierPreservation,
    identifierInstructions: identifierInstructions,
  );
}

WorkspaceConfig _parseWorkspace(Map<String, dynamic> yaml, WorkspaceConfig defaults, List<String> warns) {
  var gitSyncEnabled = defaults.gitSyncEnabled;
  var gitSyncPushEnabled = defaults.gitSyncPushEnabled;

  final workspaceMap = _sectionMap('workspace', yaml, warns);
  if (workspaceMap != null) {
    final gsMap = readMap('git_sync', workspaceMap, warns);
    if (gsMap != null) {
      gitSyncEnabled = readBool('enabled', gsMap, warns, defaultValue: gitSyncEnabled) ?? gitSyncEnabled;
      gitSyncPushEnabled =
          readBool('push_enabled', gsMap, warns, defaultValue: gitSyncPushEnabled) ?? gitSyncPushEnabled;
    }
  }

  return WorkspaceConfig(gitSyncEnabled: gitSyncEnabled, gitSyncPushEnabled: gitSyncPushEnabled);
}

OnboardingConfig _parseOnboarding(Map<String, dynamic> yaml, OnboardingConfig defaults, List<String> warns) {
  var expiryDays = defaults.expiryDays;

  final onboardingMap = _sectionMap('onboarding', yaml, warns);
  if (onboardingMap != null) {
    expiryDays = readInt('expiry_days', onboardingMap, warns, defaultValue: expiryDays) ?? expiryDays;
    if (expiryDays < 1) {
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

SearchConfig _parseSearch(
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
    final backendVal = readString('backend', searchMap, warns);
    if (backendVal != null) {
      if (backendVal == 'fts5' || backendVal == 'qmd') {
        backend = backendVal;
      } else {
        warns.add('Invalid search.backend: "$backendVal" — using default');
      }
    }
    final qmdMap = readMap('qmd', searchMap, warns);
    if (qmdMap != null) {
      qmdHost = readString('host', qmdMap, warns, defaultValue: qmdHost) ?? qmdHost;
      qmdPort = readInt('port', qmdMap, warns, defaultValue: defaults.qmdPort) ?? defaults.qmdPort;
    }
    final depth = readString('default_depth', searchMap, warns);
    if (depth != null) defaultDepth = depth;

    final providersMap = readMap('providers', searchMap, warns);
    if (providersMap != null) {
      for (final entry in providersMap.entries) {
        final name = entry.key.toString();
        final value = entry.value;
        if (value is! Map) {
          // reason: dynamic key interpolation — per-provider name can't use readX helpers
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

ProvidersConfig _parseProviders(
  Map<String, dynamic> yaml,
  Map<String, String> env,
  ProvidersConfig defaults,
  List<String> warns,
) {
  final providersRaw = readMap('providers', yaml, warns);
  if (providersRaw == null) return defaults;

  final entries = <String, ProviderEntry>{};
  for (final entry in providersRaw.entries) {
    final providerId = entry.key.toString();
    final value = entry.value;
    if (value is! Map) {
      // reason: dynamic key interpolation — per-provider id can't use readX helpers
      warns.add('Invalid type for providers.$providerId: "${value.runtimeType}" — skipping');
      continue;
    }

    final providerMap = Map<String, dynamic>.from(value);
    final executableRaw = providerMap['executable'];
    if (executableRaw is! String || executableRaw.trim().isEmpty) {
      warns.add('providers.$providerId missing "executable" — skipping');
      continue;
    }

    final poolSizeRaw = providerMap['pool_size'];
    // reason: dynamic key interpolation — per-provider pool_size can't use readX helpers
    if (poolSizeRaw != null && poolSizeRaw is! int) {
      warns.add('Invalid type for providers.$providerId.pool_size: "${poolSizeRaw.runtimeType}" — using default');
    }
    final poolSize = poolSizeRaw is int ? poolSizeRaw : 0;

    final options = Map<String, dynamic>.from(providerMap)
      ..remove('executable')
      ..remove('pool_size');
    if (ProviderIdentity.family(providerId) == ProviderIdentity.claude) {
      final inheritUserSettingsRaw = providerMap[ClaudeProviderOptions.inheritUserSettingsKey];
      if (inheritUserSettingsRaw != null && inheritUserSettingsRaw is! bool) {
        warns.add(
          'Invalid type for providers.$providerId.inherit_user_settings: '
          '"${inheritUserSettingsRaw.runtimeType}" — using default',
        );
      }
      options[ClaudeProviderOptions.inheritUserSettingsKey] = ClaudeProviderOptions.normalizeInheritUserSettings(
        inheritUserSettingsRaw,
      );
    }

    entries[providerId] = ProviderEntry(
      executable: expandHome(executableRaw.trim(), env: env),
      poolSize: poolSize,
      options: options,
    );
  }

  return ProvidersConfig(entries: entries);
}

CredentialsConfig _parseCredentials(
  Map<String, dynamic> yaml,
  Map<String, String> env,
  CredentialsConfig defaults,
  List<String> warns,
) {
  final credentialsRaw = readMap('credentials', yaml, warns);
  if (credentialsRaw == null) return defaults;

  final entries = <String, CredentialEntry>{};
  for (final entry in credentialsRaw.entries) {
    final credentialName = entry.key.toString();
    final value = entry.value;
    if (value is! Map) {
      // reason: dynamic key interpolation — per-credential name can't use readX helpers
      warns.add('Invalid type for credentials.$credentialName: "${value.runtimeType}" — skipping');
      continue;
    }

    final credentialMap = Map<String, dynamic>.from(value);
    final credentialTypeRaw = credentialMap['type'];
    final credentialType = switch (credentialTypeRaw) {
      null => null,
      'api-key' || 'apiKey' => CredentialType.apiKey,
      'github-token' || 'githubToken' => CredentialType.githubToken,
      _ => null,
    };

    if (credentialTypeRaw != null && credentialType == null) {
      warns.add('credentials.$credentialName has unknown "type" "$credentialTypeRaw" — skipping');
      continue;
    }

    switch (credentialType ?? CredentialType.apiKey) {
      case CredentialType.apiKey:
        final apiKeyRaw = credentialMap['api_key'];
        if (apiKeyRaw is! String) {
          warns.add('credentials.$credentialName missing "api_key" — skipping');
          continue;
        }
        entries[credentialName] = CredentialEntry(
          apiKey: envSubstitute(apiKeyRaw, env: env),
          envVars: envReferences(apiKeyRaw),
        );

      case CredentialType.githubToken:
        final tokenRaw = credentialMap['token'];
        if (tokenRaw is! String) {
          warns.add('credentials.$credentialName missing "token" — skipping');
          continue;
        }
        final repositoryRaw = credentialMap['repository'];
        final repository = repositoryRaw is String ? repositoryRaw.trim() : null;
        entries[credentialName] = CredentialEntry.githubToken(
          token: envSubstitute(tokenRaw, env: env),
          repository: repository == null || repository.isEmpty ? null : repository,
          envVars: envReferences(tokenRaw),
        );
    }
  }

  return CredentialsConfig(entries: entries);
}

SecurityConfig _parseSecurity(Map<String, dynamic> yaml, SecurityConfig defaults, List<String> warns) {
  final guardsMap = readMap('guards', yaml, warns);
  final guardsYaml = guardsMap ?? <String, dynamic>{};
  final guards = guardsMap == null
      ? const GuardConfig.defaults()
      : () {
          try {
            return GuardConfig.fromYaml(guardsYaml, warns);
          } catch (e) {
            warns.add('Error parsing guards config: $e — using defaults');
            return const GuardConfig.defaults();
          }
        }();

  var contentGuardEnabled = defaults.contentGuardEnabled;
  var contentGuardClassifier = defaults.contentGuardClassifier;
  var contentGuardModel = defaults.contentGuardModel;
  var contentGuardMaxBytes = defaults.contentGuardMaxBytes;
  final contentMap = guardsMap != null ? readMap('content', guardsMap, warns) : null;
  if (contentMap != null) {
    contentGuardEnabled =
        readBool('enabled', contentMap, warns, defaultValue: contentGuardEnabled) ?? contentGuardEnabled;
    final classifierVal = readString('classifier', contentMap, warns);
    if (classifierVal != null) {
      if (classifierVal == 'claude_binary' || classifierVal == 'anthropic_api') {
        contentGuardClassifier = classifierVal;
      } else {
        warns.add('Invalid guards.content.classifier: "$classifierVal" — using default');
      }
    }
    final modelVal = readString('model', contentMap, warns);
    if (modelVal != null) contentGuardModel = modelVal;
    contentGuardMaxBytes =
        readInt('max_bytes', contentMap, warns, defaultValue: defaults.contentGuardMaxBytes) ??
        defaults.contentGuardMaxBytes;
  }

  var inputSanitizerEnabled = defaults.inputSanitizerEnabled;
  var inputSanitizerChannelsOnly = defaults.inputSanitizerChannelsOnly;
  final isMap = guardsMap != null ? readMap('input_sanitizer', guardsMap, warns) : null;
  if (isMap != null) {
    inputSanitizerEnabled =
        readBool('enabled', isMap, warns, defaultValue: inputSanitizerEnabled) ?? inputSanitizerEnabled;
    inputSanitizerChannelsOnly =
        readBool('channels_only', isMap, warns, defaultValue: inputSanitizerChannelsOnly) ?? inputSanitizerChannelsOnly;
  }

  var bashStepEnvAllowlist = List<String>.from(defaults.bashStep.envAllowlist);
  var bashStepExtraStripPatterns = List<String>.from(defaults.bashStep.extraStripPatterns);
  final securityMap = readMap('security', yaml, warns);
  final bashStepMap = securityMap != null ? readMap('bash_step', securityMap, warns) : null;
  if (bashStepMap != null) {
    final allowlistList = readField<List<dynamic>>('env_allowlist', bashStepMap, warns);
    if (allowlistList != null) {
      final extensions = allowlistList.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      for (final e in allowlistList.where((e) => e is! String || e.trim().isEmpty)) {
        warns.add('Invalid value for security.bash_step.env_allowlist entry: "$e" — ignoring');
      }
      bashStepEnvAllowlist = {...defaults.bashStep.envAllowlist, ...extensions}.toList()..sort();
    }

    final extraStripList = readField<List<dynamic>>('extra_strip_patterns', bashStepMap, warns);
    if (extraStripList != null) {
      for (final e in extraStripList.where((e) => e is! String || e.trim().isEmpty)) {
        warns.add('Invalid value for security.bash_step.extra_strip_patterns entry: "$e" — ignoring');
      }
      bashStepExtraStripPatterns = extraStripList
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
  }

  final guardAuditMap = readMap('guard_audit', yaml, warns);
  if (guardAuditMap != null && guardAuditMap.containsKey('max_entries')) {
    warns.add(
      'guard_audit.max_entries is deprecated and ignored — '
      'use guard_audit.max_retention_days for audit retention',
    );
  }
  final guardAuditMaxRetentionDays =
      ((readInt('max_retention_days', guardAuditMap ?? {}, warns, defaultValue: defaults.guardAuditMaxRetentionDays) ??
              defaults.guardAuditMaxRetentionDays))
          .clamp(0, 365);

  return SecurityConfig(
    guards: guards,
    guardsYaml: guardsYaml,
    bashStep: SecurityBashStepConfig(
      envAllowlist: bashStepEnvAllowlist,
      extraStripPatterns: bashStepExtraStripPatterns,
    ),
    contentGuardEnabled: contentGuardEnabled,
    contentGuardClassifier: contentGuardClassifier,
    contentGuardModel: contentGuardModel,
    contentGuardMaxBytes: contentGuardMaxBytes,
    inputSanitizerEnabled: inputSanitizerEnabled,
    inputSanitizerChannelsOnly: inputSanitizerChannelsOnly,
    guardAuditMaxRetentionDays: guardAuditMaxRetentionDays,
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
    maxBytes = _parseInt('memory_max_bytes', cli['memory_max_bytes'], legacyTopLevelMaxBytes, defaults.maxBytes, warns);
  }

  final pruningMap = pruningRaw is Map ? pruningRaw : null;
  pruningEnabled = _parseBool(
    'memory.pruning.enabled',
    cli['memory_pruning_enabled'],
    pruningMap?['enabled'],
    pruningEnabled,
    warns,
  );
  archiveAfterDays = _parseInt(
    'memory.pruning.archive_after_days',
    cli['memory_pruning_archive_after_days'],
    pruningMap?['archive_after_days'],
    defaults.archiveAfterDays,
    warns,
  );
  if (cli['memory_pruning_schedule'] case final cliSchedule?) {
    pruningSchedule = cliSchedule;
  } else if (pruningMap?['schedule'] is String) {
    pruningSchedule = pruningMap!['schedule'] as String;
  }

  return MemoryConfig(
    maxBytes: maxBytes,
    pruningEnabled: pruningEnabled,
    archiveAfterDays: archiveAfterDays,
    pruningSchedule: pruningSchedule,
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
      intervalMinutes:
          (readInt('interval_minutes', inboxMap, warns, defaultValue: inbox.intervalMinutes) ?? inbox.intervalMinutes)
              .clamp(1, 1440)
              .toInt(),
      maxBytes: (readInt('max_bytes', inboxMap, warns, defaultValue: inbox.maxBytes) ?? inbox.maxBytes)
          .clamp(1, 50 * 1024 * 1024)
          .toInt(),
      retryAttempts:
          (readInt('retry_attempts', inboxMap, warns, defaultValue: inbox.retryAttempts) ?? inbox.retryAttempts)
              .clamp(0, 10)
              .toInt(),
      processedRetentionDays:
          (readInt('processed_retention_days', inboxMap, warns, defaultValue: inbox.processedRetentionDays) ??
                  inbox.processedRetentionDays)
              .clamp(0, 3650)
              .toInt(),
      deliveryMode: _knowledgeDeliveryMode(inboxMap['delivery_mode'], inbox.deliveryMode, 'knowledge.inbox', warns),
    );
  }

  var wikiLint = defaults.wikiLint;
  final wikiLintMap = readMap('wiki_lint', knowledgeMap, warns);
  if (wikiLintMap != null) {
    wikiLint = KnowledgeWikiLintConfig(
      enabled: readBool('enabled', wikiLintMap, warns, defaultValue: wikiLint.enabled) ?? wikiLint.enabled,
      intervalMinutes:
          (readInt('interval_minutes', wikiLintMap, warns, defaultValue: wikiLint.intervalMinutes) ??
                  wikiLint.intervalMinutes)
              .clamp(1, 1440)
              .toInt(),
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
  return containerMap != null ? ContainerConfig.fromYaml(containerMap, warns) : const ContainerConfig.disabled();
}

ChannelConfig _parseChannels(Map<String, dynamic> yaml, List<String> warns) {
  final channelsMap = readMap('channels', yaml, warns);
  return channelsMap != null ? ChannelConfig.fromYaml(channelsMap, warns) : const ChannelConfig.defaults();
}

TaskConfig _parseTasks(Map<String, dynamic> yaml, TaskConfig defaults, List<String> warns) {
  var maxConcurrent = defaults.maxConcurrent;
  var artifactRetentionDays = defaults.artifactRetentionDays;
  var completionAction = defaults.completionAction;
  var worktreeBaseRef = defaults.worktreeBaseRef;
  var worktreeStaleTimeoutHours = defaults.worktreeStaleTimeoutHours;
  var worktreeMergeStrategy = defaults.worktreeMergeStrategy;

  final tasksMap = _sectionMap('tasks', yaml, warns);
  if (tasksMap != null) {
    maxConcurrent =
        (readInt('max_concurrent', tasksMap, warns, defaultValue: defaults.maxConcurrent) ?? defaults.maxConcurrent)
            .clamp(1, 10);
    artifactRetentionDays =
        (readInt('artifact_retention_days', tasksMap, warns, defaultValue: defaults.artifactRetentionDays) ??
                defaults.artifactRetentionDays)
            .clamp(0, 3650);
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
      worktreeStaleTimeoutHours =
          (readInt('stale_timeout_hours', worktreeMap, warns, defaultValue: defaults.worktreeStaleTimeoutHours) ??
                  defaults.worktreeStaleTimeoutHours)
              .clamp(1, 168);
      final ms = worktreeMap['merge_strategy'];
      if (ms is String) {
        if (ms == 'squash' || ms == 'merge') {
          worktreeMergeStrategy = ms;
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
    maxConcurrent: maxConcurrent,
    artifactRetentionDays: artifactRetentionDays,
    completionAction: completionAction,
    worktreeBaseRef: worktreeBaseRef,
    worktreeStaleTimeoutHours: worktreeStaleTimeoutHours,
    worktreeMergeStrategy: worktreeMergeStrategy,
    budget: budget,
  );
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
    warns.add('Ignoring retired andthen.$key config; DartClaw no longer provisions AndThen skills.');
  }
}
