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
  'workflow',
  'search',
  'usage',
  'guard_audit',
  'memory',
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

Map<String, dynamic>? _sectionMap(String key, Map<String, dynamic> yaml, List<String> warns) {
  final raw = yaml[key];
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw != null) {
    warns.add('Invalid type for $key: "${raw.runtimeType}" — using defaults');
  }
  return null;
}

ServerConfig _parseTopLevel(
  Map<String, dynamic> yaml,
  Map<String, String> cli,
  Map<String, String> env,
  ServerConfig defaults,
  List<String> warns,
) {
  final port = _parseInt('port', cli['port'], yaml['port'], defaults.port, warns);
  final host = _parseString('host', cli['host'], yaml['host'], defaults.host, env, warns);
  final name = _parseString('name', cli['name'], yaml['name'], defaults.name, env, warns);
  String? baseUrl = defaults.baseUrl;
  final rawBaseUrl = yaml['base_url'];
  if (rawBaseUrl is String) {
    final normalized = envSubstitute(rawBaseUrl, env: env).trim();
    baseUrl = normalized.isEmpty ? null : normalized;
  } else if (rawBaseUrl != null) {
    warns.add('Invalid type for base_url: "${rawBaseUrl.runtimeType}" — using default');
  }
  final workerTimeout = _parseInt(
    'worker_timeout',
    cli['worker_timeout'],
    yaml['worker_timeout'],
    defaults.workerTimeout,
    warns,
  );

  final defaultDataDir = env['DARTCLAW_HOME'] ?? defaults.dataDir;
  final rawDataDir = cli['data_dir'] ?? _yamlString('data_dir', yaml['data_dir'], defaultDataDir, env, warns);
  final dataDir = expandHome(rawDataDir, env: env);
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

AgentConfig _parseAgent(Map<String, dynamic> yaml, AgentConfig defaults, List<String> warns) {
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
  final historyMap = agentMap?['history'];
  if (historyMap is Map) {
    var maxMessageChars = historyConfig.maxMessageChars;
    var maxTotalChars = historyConfig.maxTotalChars;

    final mmc = historyMap['max_message_chars'];
    if (mmc is int && mmc >= 500) {
      maxMessageChars = mmc;
    } else if (mmc != null) {
      warns.add('Invalid agent.history.max_message_chars: $mmc (must be int >= 500) — using default');
    }

    final mtc = historyMap['max_total_chars'];
    if (mtc is int && mtc >= 5000) {
      maxTotalChars = mtc;
    } else if (mtc != null) {
      warns.add('Invalid agent.history.max_total_chars: $mtc (must be int >= 5000) — using default');
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

  var enabled = defaults.enabled;
  final enabledRaw = advisorMap['enabled'];
  if (enabledRaw is bool) {
    enabled = enabledRaw;
  } else if (enabledRaw != null) {
    warns.add('Invalid type for advisor.enabled: "${enabledRaw.runtimeType}" — using default');
  }

  String? model = defaults.model;
  final modelRaw = advisorMap['model'];
  if (modelRaw is String) {
    final trimmed = modelRaw.trim();
    model = trimmed.isEmpty ? null : trimmed;
    _warnIfUnrecognizedModel(warns, 'advisor.model', model);
  } else if (modelRaw != null) {
    warns.add('Invalid type for advisor.model: "${modelRaw.runtimeType}" — using default');
  }

  String? effort = defaults.effort;
  final effortRaw = advisorMap['effort'];
  if (effortRaw is String) {
    final trimmed = effortRaw.trim();
    effort = trimmed.isEmpty ? null : trimmed;
  } else if (effortRaw != null) {
    warns.add('Invalid type for advisor.effort: "${effortRaw.runtimeType}" — using default');
  }

  var triggers = defaults.triggers;
  final triggersRaw = advisorMap['triggers'];
  if (triggersRaw is List) {
    final parsed = <String>[];
    for (final value in triggersRaw) {
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
  } else if (triggersRaw != null) {
    warns.add('Invalid type for advisor.triggers: "${triggersRaw.runtimeType}" — using default');
  }

  final periodicIntervalMinutes = _parseInt(
    'advisor.periodic_interval_minutes',
    null,
    advisorMap['periodic_interval_minutes'],
    defaults.periodicIntervalMinutes,
    warns,
  );
  final maxWindowTurns = _parseInt(
    'advisor.max_window_turns',
    null,
    advisorMap['max_window_turns'],
    defaults.maxWindowTurns,
    warns,
  );
  final maxPriorReflections = _parseInt(
    'advisor.max_prior_reflections',
    null,
    advisorMap['max_prior_reflections'],
    defaults.maxPriorReflections,
    warns,
  );

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

  final reload = _parseReloadConfig(gMap, defaults.reload, warns);
  return GatewayConfig(authMode: authMode, token: token, hsts: hsts, reload: reload);
}

ReloadConfig _parseReloadConfig(Map<dynamic, dynamic>? gMap, ReloadConfig defaults, List<String> warns) {
  if (gMap == null) return defaults;
  final reloadRaw = gMap['reload'];
  if (reloadRaw == null) return defaults;
  if (reloadRaw is! Map) {
    warns.add('Invalid type for gateway.reload: "${reloadRaw.runtimeType}" — using default');
    return defaults;
  }
  final rMap = Map<String, dynamic>.from(reloadRaw);

  var mode = defaults.mode;
  var debounceMs = defaults.debounceMs;

  final modeVal = rMap['mode'];
  if (modeVal is String) {
    if (modeVal == 'off' || modeVal == 'signal' || modeVal == 'auto') {
      mode = modeVal;
    } else {
      warns.add('Invalid gateway.reload.mode: "$modeVal" — using default "${defaults.mode}"');
    }
  } else if (modeVal != null) {
    warns.add('Invalid type for gateway.reload.mode: "${modeVal.runtimeType}" — using default');
  }

  final debounceVal = rMap['debounce_ms'];
  if (debounceVal is int) {
    if (debounceVal >= 100) {
      debounceMs = debounceVal;
    } else {
      warns.add('gateway.reload.debounce_ms must be >= 100, got $debounceVal — using default ${defaults.debounceMs}');
    }
  } else if (debounceVal != null) {
    warns.add('Invalid type for gateway.reload.debounce_ms: "${debounceVal.runtimeType}" — using default');
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

SessionScopeConfig _parseSessionScope(
  Map<dynamic, dynamic> sessionsRaw,
  SessionScopeConfig defaultScope,
  List<String> warns,
) {
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

  var model = defaultScope.model;
  final modelRaw = sessionsRaw['model'];
  if (modelRaw is String) {
    model = modelRaw;
    _warnIfUnrecognizedModel(warns, 'sessions.model', model);
  } else if (modelRaw != null) {
    warns.add('Invalid type for sessions.model: "${modelRaw.runtimeType}" — using default');
  }

  var effort = defaultScope.effort;
  final effortRaw = sessionsRaw['effort'];
  if (effortRaw is String) {
    effort = effortRaw;
  } else if (effortRaw != null) {
    warns.add('Invalid type for sessions.effort: "${effortRaw.runtimeType}" — using default');
  }

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

      String? chModel;
      final chModelRaw = channelMap['model'];
      if (chModelRaw is String) {
        chModel = chModelRaw;
        _warnIfUnrecognizedModel(warns, 'sessions.channels.$channelName.model', chModel);
      } else if (chModelRaw != null) {
        warns.add('Invalid type for sessions.channels.$channelName.model: "${chModelRaw.runtimeType}" — ignoring');
      }

      String? chEffort;
      final chEffortRaw = channelMap['effort'];
      if (chEffortRaw is String) {
        chEffort = chEffortRaw;
      } else if (chEffortRaw != null) {
        warns.add('Invalid type for sessions.channels.$channelName.effort: "${chEffortRaw.runtimeType}" — ignoring');
      }

      if (chDmScope != null || chGroupScope != null || chModel != null || chEffort != null) {
        channelOverrides[channelName] = ChannelScopeConfig(
          dmScope: chDmScope,
          groupScope: chGroupScope,
          model: chModel,
          effort: chEffort,
        );
      }
    }
  } else if (channelsRaw != null) {
    warns.add('Invalid type for sessions.channels: "${channelsRaw.runtimeType}" — skipping overrides');
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
  final maintRaw = sessionsRaw['maintenance'];
  if (maintRaw is! Map) {
    if (maintRaw != null) {
      warns.add('Invalid type for sessions.maintenance: "${maintRaw.runtimeType}" — using defaults');
    }
    return defaultMaint;
  }

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

    final ipRaw = contextMap['identifier_preservation'];
    if (ipRaw is String) {
      const validValues = {'strict', 'off', 'custom'};
      if (validValues.contains(ipRaw)) {
        identifierPreservation = ipRaw;
      } else {
        warns.add(
          'Invalid value for context.identifier_preservation: "$ipRaw" — '
          'expected one of ${validValues.join(', ')}; using default "strict"',
        );
      }
    } else if (ipRaw != null) {
      warns.add(
        'Invalid type for context.identifier_preservation: '
        '"${ipRaw.runtimeType}" — using default "strict"',
      );
    }

    final iiRaw = contextMap['identifier_instructions'];
    if (iiRaw is String && iiRaw.trim().isNotEmpty) {
      identifierInstructions = iiRaw;
    } else if (iiRaw != null && iiRaw is! String) {
      warns.add(
        'Invalid type for context.identifier_instructions: '
        '"${iiRaw.runtimeType}" — ignoring',
      );
    }
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

SchedulingConfig _parseScheduling(Map<String, dynamic> yaml, SchedulingConfig defaults, List<String> warns) {
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

ProvidersConfig _parseProviders(
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

CredentialsConfig _parseCredentials(
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
  final guardsRaw = yaml['guards'];
  final guardsYaml = guardsRaw is Map ? Map<String, dynamic>.from(guardsRaw) : <String, dynamic>{};
  final securityRaw = yaml['security'];
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

  var bashStepEnvAllowlist = List<String>.from(defaults.bashStep.envAllowlist);
  var bashStepExtraStripPatterns = List<String>.from(defaults.bashStep.extraStripPatterns);
  if (securityRaw is Map) {
    final bashStepRaw = securityRaw['bash_step'];
    if (bashStepRaw is Map) {
      final allowlistRaw = bashStepRaw['env_allowlist'];
      if (allowlistRaw is List) {
        final extensions = <String>[];
        for (final entry in allowlistRaw) {
          if (entry is! String || entry.trim().isEmpty) {
            warns.add('Invalid value for security.bash_step.env_allowlist entry: "$entry" — ignoring');
            continue;
          }
          extensions.add(entry.trim());
        }
        bashStepEnvAllowlist = {...defaults.bashStep.envAllowlist, ...extensions}.toList()..sort();
      } else if (allowlistRaw != null) {
        warns.add('Invalid type for security.bash_step.env_allowlist: "${allowlistRaw.runtimeType}" — using defaults');
      }

      final extraStripRaw = bashStepRaw['extra_strip_patterns'];
      if (extraStripRaw is List) {
        final patterns = <String>[];
        for (final entry in extraStripRaw) {
          if (entry is! String || entry.trim().isEmpty) {
            warns.add('Invalid value for security.bash_step.extra_strip_patterns entry: "$entry" — ignoring');
            continue;
          }
          patterns.add(entry.trim());
        }
        bashStepExtraStripPatterns = patterns;
      } else if (extraStripRaw != null) {
        warns.add(
          'Invalid type for security.bash_step.extra_strip_patterns: "${extraStripRaw.runtimeType}" — using defaults',
        );
      }
    } else if (bashStepRaw != null) {
      warns.add('Invalid type for security.bash_step: "${bashStepRaw.runtimeType}" — using defaults');
    }
  } else if (securityRaw != null) {
    warns.add('Invalid type for security: "${securityRaw.runtimeType}" — using defaults');
  }

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

ContainerConfig _parseContainer(Map<String, dynamic> yaml, List<String> warns) {
  final containerRaw = yaml['container'];
  final config = containerRaw is Map
      ? ContainerConfig.fromYaml(Map<String, dynamic>.from(containerRaw), warns)
      : const ContainerConfig.disabled();
  if (containerRaw != null && containerRaw is! Map) {
    warns.add('Invalid type for container: "${containerRaw.runtimeType}" — using defaults');
  }
  return config;
}

ChannelConfig _parseChannels(Map<String, dynamic> yaml, List<String> warns) {
  final channelsRaw = yaml['channels'];
  final config = channelsRaw is Map
      ? ChannelConfig.fromYaml(Map<String, dynamic>.from(channelsRaw), warns)
      : const ChannelConfig.defaults();
  if (channelsRaw != null && channelsRaw is! Map) {
    warns.add('Invalid type for channels: "${channelsRaw.runtimeType}" — using defaults');
  }
  return config;
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

  var budget = defaults.budget;
  final budgetRaw = tasksMap?['budget'];
  if (budgetRaw is Map) {
    final defaultMaxTokens = _parseInt(
      'tasks.budget.default_max_tokens',
      null,
      budgetRaw['default_max_tokens'],
      -1,
      warns,
    );
    final warningThresholdRaw = budgetRaw['warning_threshold'];
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
  } else if (budgetRaw != null) {
    warns.add('Invalid type for tasks.budget: "${budgetRaw.runtimeType}" — using defaults');
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

const _knownAndthenKeys = {'git_url', 'ref', 'network', 'source_cache_dir'};

AndthenConfig _parseAndthen(
  Map<String, dynamic> yaml,
  AndthenConfig defaults,
  Map<String, String> env,
  List<String> warns,
) {
  var gitUrl = defaults.gitUrl;
  var ref = defaults.ref;
  var network = defaults.network;
  var sourceCacheDir = defaults.sourceCacheDir;

  final atMap = _sectionMap('andthen', yaml, warns);
  if (atMap == null) return defaults;

  for (final key in atMap.keys) {
    if (key == 'install_scope') {
      warns.add(
        'andthen.install_scope is no longer supported (skills always install into the data dir); '
        'remove it from your config to silence this warning',
      );
      continue;
    }
    if (!_knownAndthenKeys.contains(key)) {
      warns.add('Unknown andthen config key: "$key" — ignoring');
    }
  }

  final gitUrlVal = atMap['git_url'];
  if (gitUrlVal is String && gitUrlVal.isNotEmpty) {
    gitUrl = gitUrlVal;
  } else if (gitUrlVal != null) {
    warns.add('Invalid type for andthen.git_url: "${gitUrlVal.runtimeType}" — using default');
  }

  final refVal = atMap['ref'];
  if (refVal is String && refVal.isNotEmpty) {
    ref = refVal;
  } else if (refVal != null) {
    warns.add('Invalid type for andthen.ref: "${refVal.runtimeType}" — using default');
  }

  final networkVal = atMap['network'];
  if (networkVal != null) {
    final parsed = parseAndthenNetworkPolicy(networkVal);
    if (parsed != null) {
      network = parsed;
    } else {
      warns.add('Invalid andthen.network: "$networkVal" — using default "${defaults.network.yamlValue}"');
    }
  }

  final sourceCacheDirVal = atMap['source_cache_dir'];
  if (sourceCacheDirVal is String) {
    final resolved = expandHome(envSubstitute(sourceCacheDirVal, env: env).trim(), env: env);
    if (resolved.isNotEmpty) {
      sourceCacheDir = resolved;
    } else {
      warns.add('Invalid empty value for andthen.source_cache_dir — using default');
    }
  } else if (sourceCacheDirVal != null) {
    warns.add('Invalid type for andthen.source_cache_dir: "${sourceCacheDirVal.runtimeType}" — using default');
  }

  return AndthenConfig(gitUrl: gitUrl, ref: ref, network: network, sourceCacheDir: sourceCacheDir);
}

int _parseInt(String key, String? cliValue, Object? yamlValue, int defaultValue, List<String> warns) {
  if (cliValue != null) {
    final parsed = int.tryParse(cliValue);
    if (parsed != null) return parsed;
    warns.add('Invalid CLI value for $key: "$cliValue" — using default');
  }
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

bool _parseBool(String key, String? cliValue, Object? yamlValue, bool defaultValue, List<String> warns) {
  if (cliValue != null) {
    if (cliValue == 'true') return true;
    if (cliValue == 'false') return false;
    warns.add('Invalid CLI value for $key: "$cliValue" — using default');
  }
  if (yamlValue is bool) return yamlValue;
  return defaultValue;
}

String _parseString(
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

String _yamlString(String key, Object? yamlValue, String defaultValue, Map<String, String> env, List<String> warns) {
  if (yamlValue == null) return defaultValue;
  if (yamlValue is! String) {
    warns.add('Invalid type for $key: "${yamlValue.runtimeType}" — using default');
    return defaultValue;
  }
  return envSubstitute(yamlValue, env: env);
}

String? _yamlStringOrNull(String key, Object? yamlValue, Map<String, String> env, List<String> warns) {
  if (yamlValue == null) return null;
  if (yamlValue is! String) {
    warns.add('Invalid type for $key: "${yamlValue.runtimeType}" — ignoring');
    return null;
  }
  return envSubstitute(yamlValue, env: env);
}
