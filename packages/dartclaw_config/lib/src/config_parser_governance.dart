part of 'dartclaw_config.dart';

// Legacy CLI-aware helpers — kept here so config_parser.dart can stay under the LOC budget.
// These handle both CLI overrides and YAML values; readX helpers only handle YAML.

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
    // reason: legacy CLI-aware helper; readX can't handle CLI overrides
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
    // reason: legacy env-substituting string helper used with CLI-override callers
    warns.add('Invalid type for $key: "${yamlValue.runtimeType}" — using default');
    return defaultValue;
  }
  return envSubstitute(yamlValue, env: env);
}

String? _yamlStringOrNull(String key, Object? yamlValue, Map<String, String> env, List<String> warns) {
  if (yamlValue == null) return null;
  if (yamlValue is! String) {
    // reason: legacy env-substituting nullable-string helper used with CLI-override callers
    warns.add('Invalid type for $key: "${yamlValue.runtimeType}" — ignoring');
    return null;
  }
  return envSubstitute(yamlValue, env: env);
}

GovernanceConfig _parseGovernance(Map<String, dynamic> yaml, GovernanceConfig defaults, List<String> warns) {
  final govMap = _sectionMap('governance', yaml, warns);
  if (govMap == null) return defaults;

  final adminSenders =
      readStringList('admin_senders', govMap, warns, defaultValue: defaults.adminSenders) ?? defaults.adminSenders;

  var rateLimits = defaults.rateLimits;
  final rateLimitsMap = readMap('rate_limits', govMap, warns);
  if (rateLimitsMap != null) {
    var perSender = rateLimits.perSender;
    var global = rateLimits.global;

    final perSenderMap = readMap('per_sender', rateLimitsMap, warns);
    if (perSenderMap != null) {
      perSender = PerSenderRateLimitConfig(
        messages: readInt('messages', perSenderMap, warns, defaultValue: perSender.messages) ?? perSender.messages,
        windowMinutes: _parseDurationMinutes(perSenderMap['window']) ?? perSender.windowMinutes,
        maxQueued: readInt('max_queued', perSenderMap, warns, defaultValue: perSender.maxQueued) ?? perSender.maxQueued,
        maxPauseQueued:
            readInt('max_pause_queued', perSenderMap, warns, defaultValue: perSender.maxPauseQueued) ??
            perSender.maxPauseQueued,
      );
    }

    final globalMap = readMap('global', rateLimitsMap, warns);
    if (globalMap != null) {
      global = GlobalRateLimitConfig(
        turns: readInt('turns', globalMap, warns, defaultValue: global.turns) ?? global.turns,
        windowMinutes: _parseDurationMinutes(globalMap['window']) ?? global.windowMinutes,
      );
    }

    rateLimits = RateLimitsConfig(perSender: perSender, global: global);
  }

  var queueStrategy = defaults.queueStrategy;
  final queueStrategyRaw = readString('queue_strategy', govMap, warns);
  if (queueStrategyRaw != null) {
    final parsed = QueueStrategy.fromYaml(queueStrategyRaw);
    if (parsed != null) {
      queueStrategy = parsed;
    } else {
      warns.add('Unknown governance.queue_strategy: "$queueStrategyRaw" — using default "${queueStrategy.name}"');
    }
  }

  var crowdCoding = defaults.crowdCoding;
  final crowdCodingMap = readMap('crowd_coding', govMap, warns);
  if (crowdCodingMap != null) {
    final modelRaw = readString('model', crowdCodingMap, warns);
    var model = crowdCoding.model;
    if (modelRaw != null) {
      model = modelRaw;
      _warnIfUnrecognizedModel(warns, 'governance.crowd_coding.model', model);
    }
    final effort = readString('effort', crowdCodingMap, warns, defaultValue: crowdCoding.effort) ?? crowdCoding.effort;
    crowdCoding = CrowdCodingConfig(model: model, effort: effort);
  }

  var turnProgress = defaults.turnProgress;
  final turnProgressMap = readMap('turn_progress', govMap, warns);
  if (turnProgressMap != null) {
    final stallTimeoutRaw = turnProgressMap['stall_timeout'];
    final parsedTimeout = tryParseDuration(stallTimeoutRaw);
    final stallTimeout = parsedTimeout ?? turnProgress.stallTimeout;
    if (stallTimeoutRaw != null && parsedTimeout == null) {
      warns.add('Invalid value for governance.turn_progress.stall_timeout: "$stallTimeoutRaw" — using default');
    }

    var stallAction = turnProgress.stallAction;
    final stallActionRaw = readString('stall_action', turnProgressMap, warns);
    if (stallActionRaw != null) {
      final parsed = TurnProgressAction.fromYaml(stallActionRaw);
      if (parsed != null) {
        stallAction = parsed;
      } else {
        warns.add(
          'Unknown governance.turn_progress.stall_action: '
          '"$stallActionRaw" — using default "${turnProgress.stallAction.name}"',
        );
      }
    }

    turnProgress = TurnProgressConfig(stallTimeout: stallTimeout, stallAction: stallAction);
  }

  var budget = defaults.budget;
  final budgetMap = readMap('budget', govMap, warns);
  if (budgetMap != null) {
    final dailyTokens =
        readInt('daily_tokens', budgetMap, warns, defaultValue: budget.dailyTokens) ?? budget.dailyTokens;
    var action = budget.action;
    final actionRaw = readString('action', budgetMap, warns);
    if (actionRaw != null) {
      final parsedAction = BudgetAction.fromYaml(actionRaw);
      if (parsedAction != null) {
        action = parsedAction;
      } else {
        warns.add('Unknown governance.budget.action: "$actionRaw" — using default "${budget.action.name}"');
      }
    }
    final timezoneRaw = readString('timezone', budgetMap, warns);
    final timezone = (timezoneRaw != null && timezoneRaw.isNotEmpty) ? timezoneRaw : budget.timezone;

    budget = BudgetConfig(dailyTokens: dailyTokens, action: action, timezone: timezone);
  }

  var loopDetection = defaults.loopDetection;
  final loopMap = readMap('loop_detection', govMap, warns);
  if (loopMap != null) {
    final enabled = readBool('enabled', loopMap, warns, defaultValue: loopDetection.enabled) ?? loopDetection.enabled;
    final maxConsecutiveTurns =
        readInt('max_consecutive_turns', loopMap, warns, defaultValue: loopDetection.maxConsecutiveTurns) ??
        loopDetection.maxConsecutiveTurns;
    final maxTokensPerMinute =
        readInt('max_tokens_per_minute', loopMap, warns, defaultValue: loopDetection.maxTokensPerMinute) ??
        loopDetection.maxTokensPerMinute;
    final velocityWindowMinutes =
        readInt('velocity_window_minutes', loopMap, warns, defaultValue: loopDetection.velocityWindowMinutes) ??
        loopDetection.velocityWindowMinutes;
    final maxConsecutiveIdenticalToolCalls =
        readInt(
          'max_consecutive_identical_tool_calls',
          loopMap,
          warns,
          defaultValue: loopDetection.maxConsecutiveIdenticalToolCalls,
        ) ??
        loopDetection.maxConsecutiveIdenticalToolCalls;

    var action = loopDetection.action;
    final actionRaw = readString('action', loopMap, warns);
    if (actionRaw != null) {
      final parsedAction = LoopAction.fromYaml(actionRaw);
      if (parsedAction != null) {
        action = parsedAction;
      } else {
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
  }

  return GovernanceConfig(
    adminSenders: adminSenders,
    rateLimits: rateLimits,
    budget: budget,
    loopDetection: loopDetection,
    queueStrategy: queueStrategy,
    crowdCoding: crowdCoding,
    turnProgress: turnProgress,
  );
}

CanvasConfig _parseCanvas(Map<String, dynamic> yaml, CanvasConfig defaults, List<String> warns) {
  final canvasMap = _sectionMap('canvas', yaml, warns);
  if (canvasMap == null) return defaults;

  final enabled = readBool('enabled', canvasMap, warns, defaultValue: defaults.enabled) ?? defaults.enabled;

  var share = defaults.share;
  final shareMap = readMap('share', canvasMap, warns);
  if (shareMap != null) {
    final defaultPermissionRaw = shareMap['default_permission'];
    final defaultPermission = switch (defaultPermissionRaw) {
      String value when value.trim() == 'view' || value.trim() == 'interact' => value.trim(),
      String value => () {
        warns.add('Unknown canvas.share.default_permission: "$value" — using default "${share.defaultPermission}"');
        return share.defaultPermission;
      }(),
      null => share.defaultPermission,
      _ => () {
        warns.add(
          'Invalid type for canvas.share.default_permission: "${defaultPermissionRaw.runtimeType}" — using default',
        );
        return share.defaultPermission;
      }(),
    };
    final defaultTtlMinutes = _parseDurationMinutes(shareMap['default_ttl']) ?? share.defaultTtlMinutes;
    final maxConnections =
        readInt('max_connections', shareMap, warns, defaultValue: share.maxConnections) ?? share.maxConnections;
    final autoShare = readBool('auto_share', shareMap, warns, defaultValue: share.autoShare) ?? share.autoShare;
    final showQr = readBool('show_qr', shareMap, warns, defaultValue: share.showQr) ?? share.showQr;
    share = CanvasShareConfig(
      defaultPermission: defaultPermission,
      defaultTtlMinutes: defaultTtlMinutes,
      maxConnections: maxConnections,
      autoShare: autoShare,
      showQr: showQr,
    );
  }

  var workshopMode = defaults.workshopMode;
  final workshopMap = readMap('workshop_mode', canvasMap, warns);
  if (workshopMap != null) {
    workshopMode = CanvasWorkshopConfig(
      taskBoard:
          readBool('task_board', workshopMap, warns, defaultValue: workshopMode.taskBoard) ?? workshopMode.taskBoard,
      showContributorStats:
          readBool('show_contributor_stats', workshopMap, warns, defaultValue: workshopMode.showContributorStats) ??
          workshopMode.showContributorStats,
      showBudgetBar:
          readBool('show_budget_bar', workshopMap, warns, defaultValue: workshopMode.showBudgetBar) ??
          workshopMode.showBudgetBar,
    );
  }

  return CanvasConfig(enabled: enabled, share: share, workshopMode: workshopMode);
}

int? _parseDurationMinutes(Object? value) {
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
    final secs = int.tryParse(s.substring(0, s.length - 1));
    return secs != null ? secs ~/ 60 : null;
  }
  return int.tryParse(s);
}

({List<Map<String, dynamic>> convertedJobs, List<ScheduledTaskDefinition> taskDefs}) _parseAutomation(
  Map<String, dynamic> yaml,
  List<String> warns,
) {
  const empty = (convertedJobs: <Map<String, dynamic>>[], taskDefs: <ScheduledTaskDefinition>[]);
  final automationMap = readMap('automation', yaml, warns);
  if (automationMap == null) return empty;

  final tasksRaw = automationMap['scheduled_tasks'];
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

  final convertedJobs = <Map<String, dynamic>>[
    for (final def in taskDefs) {'type': 'task', ...def.toJson()},
  ];

  return (convertedJobs: convertedJobs, taskDefs: taskDefs);
}

AlertsConfig _parseAlerts(Map<String, dynamic> yaml, AlertsConfig defaults, List<String> warns) {
  final alertsMap = _sectionMap('alerts', yaml, warns);
  if (alertsMap == null) return defaults;

  final enabled = readBool('enabled', alertsMap, warns, defaultValue: defaults.enabled) ?? defaults.enabled;

  var cooldownSeconds = defaults.cooldownSeconds;
  final cooldownRead = readInt('cooldown_seconds', alertsMap, warns, defaultValue: defaults.cooldownSeconds);
  if (cooldownRead != null) {
    if (cooldownRead >= 1) {
      cooldownSeconds = cooldownRead;
    } else {
      warns.add('alerts.cooldown_seconds must be >= 1 — using default');
    }
  }

  var burstThreshold = defaults.burstThreshold;
  final burstRead = readInt('burst_threshold', alertsMap, warns, defaultValue: defaults.burstThreshold);
  if (burstRead != null) {
    if (burstRead >= 1) {
      burstThreshold = burstRead;
    } else {
      warns.add('alerts.burst_threshold must be >= 1 — using default');
    }
  }

  final targets = <AlertTarget>[];
  final targetsRaw = alertsMap['targets'];
  if (targetsRaw is List) {
    for (final (i, entry) in targetsRaw.indexed) {
      if (entry is! Map) {
        warns.add('alerts.targets[$i] must be a map — skipping');
        continue;
      }
      final channel = entry['channel'];
      final recipient = entry['recipient'];
      if (channel is! String || channel.isEmpty) {
        warns.add('alerts.targets[$i].channel must be a non-empty string — skipping');
        continue;
      }
      if (recipient is! String || recipient.isEmpty) {
        warns.add('alerts.targets[$i].recipient must be a non-empty string — skipping');
        continue;
      }
      targets.add(AlertTarget(channel: channel, recipient: recipient));
    }
  } else if (targetsRaw != null) {
    warns.add('Invalid type for alerts.targets: "${targetsRaw.runtimeType}" — using default');
  }

  final routes = <String, List<String>>{};
  final routesRaw = alertsMap['routes'];
  if (routesRaw is Map) {
    for (final entry in routesRaw.entries) {
      final key = entry.key;
      if (key is! String) {
        warns.add('alerts.routes key must be a string — skipping entry');
        continue;
      }
      final value = entry.value;
      if (value is List) {
        routes[key] = value.whereType<String>().toList();
      } else {
        warns.add('alerts.routes[$key] must be a list — skipping entry');
      }
    }
  } else if (routesRaw != null) {
    warns.add('Invalid type for alerts.routes: "${routesRaw.runtimeType}" — using default');
  }

  return AlertsConfig(
    enabled: enabled,
    cooldownSeconds: cooldownSeconds,
    burstThreshold: burstThreshold,
    targets: targets,
    routes: routes,
  );
}
