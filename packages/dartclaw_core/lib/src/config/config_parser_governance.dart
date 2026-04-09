part of 'dartclaw_config.dart';

GovernanceConfig _parseGovernance(Map<String, dynamic> yaml, GovernanceConfig defaults, List<String> warns) {
  final govMap = _sectionMap('governance', yaml, warns);
  if (govMap == null) return defaults;

  var adminSenders = defaults.adminSenders;
  final adminRaw = govMap['admin_senders'];
  if (adminRaw is List) {
    adminSenders = adminRaw.whereType<String>().toList();
  } else if (adminRaw != null) {
    warns.add('Invalid type for governance.admin_senders: "${adminRaw.runtimeType}" — using default');
  }

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
      final maxQueued = _parseInt(
        'governance.rate_limits.per_sender.max_queued',
        null,
        perSenderRaw['max_queued'],
        perSender.maxQueued,
        warns,
      );
      final maxPauseQueued = _parseInt(
        'governance.rate_limits.per_sender.max_pause_queued',
        null,
        perSenderRaw['max_pause_queued'],
        perSender.maxPauseQueued,
        warns,
      );
      perSender = PerSenderRateLimitConfig(
        messages: messages,
        windowMinutes: windowMinutes,
        maxQueued: maxQueued,
        maxPauseQueued: maxPauseQueued,
      );
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

  var queueStrategy = defaults.queueStrategy;
  final queueStrategyRaw = govMap['queue_strategy'];
  if (queueStrategyRaw is String) {
    final parsed = QueueStrategy.fromYaml(queueStrategyRaw);
    if (parsed != null) {
      queueStrategy = parsed;
    } else {
      warns.add('Unknown governance.queue_strategy: "$queueStrategyRaw" — using default "${queueStrategy.name}"');
    }
  } else if (queueStrategyRaw != null) {
    warns.add('Invalid type for governance.queue_strategy: "${queueStrategyRaw.runtimeType}" — using default');
  }

  var crowdCoding = defaults.crowdCoding;
  final crowdCodingRaw = govMap['crowd_coding'];
  if (crowdCodingRaw is Map) {
    var model = crowdCoding.model;
    final modelRaw = crowdCodingRaw['model'];
    if (modelRaw is String) {
      model = modelRaw;
      _warnIfUnrecognizedModel(warns, 'governance.crowd_coding.model', model);
    } else if (modelRaw != null) {
      warns.add('Invalid type for governance.crowd_coding.model: "${modelRaw.runtimeType}" — using default');
    }

    var effort = crowdCoding.effort;
    final effortRaw = crowdCodingRaw['effort'];
    if (effortRaw is String) {
      effort = effortRaw;
      _warnIfUnrecognizedEffort(warns, 'governance.crowd_coding.effort', effort);
    } else if (effortRaw != null) {
      warns.add('Invalid type for governance.crowd_coding.effort: "${effortRaw.runtimeType}" — using default');
    }

    crowdCoding = CrowdCodingConfig(model: model, effort: effort);
  } else if (crowdCodingRaw != null) {
    warns.add('Invalid type for governance.crowd_coding: "${crowdCodingRaw.runtimeType}" — using defaults');
  }

  var turnProgress = defaults.turnProgress;
  final turnProgressRaw = govMap['turn_progress'];
  if (turnProgressRaw is Map) {
    final parsedTimeout = tryParseDuration(turnProgressRaw['stall_timeout']);
    final stallTimeout = parsedTimeout ?? turnProgress.stallTimeout;
    if (turnProgressRaw['stall_timeout'] != null && parsedTimeout == null) {
      warns.add(
        'Invalid value for governance.turn_progress.stall_timeout: '
        '"${turnProgressRaw['stall_timeout']}" — using default',
      );
    }

    var stallAction = turnProgress.stallAction;
    final stallActionRaw = turnProgressRaw['stall_action'];
    if (stallActionRaw is String) {
      final parsed = TurnProgressAction.fromYaml(stallActionRaw);
      if (parsed != null) {
        stallAction = parsed;
      } else {
        warns.add(
          'Unknown governance.turn_progress.stall_action: '
          '"$stallActionRaw" — using default "${turnProgress.stallAction.name}"',
        );
      }
    } else if (stallActionRaw != null) {
      warns.add(
        'Invalid type for governance.turn_progress.stall_action: '
        '"${stallActionRaw.runtimeType}" — using default',
      );
    }

    turnProgress = TurnProgressConfig(stallTimeout: stallTimeout, stallAction: stallAction);
  } else if (turnProgressRaw != null) {
    warns.add('Invalid type for governance.turn_progress: "${turnProgressRaw.runtimeType}" — using defaults');
  }

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
      final parsedAction = BudgetAction.fromYaml(actionRaw);
      if (parsedAction != null) {
        action = parsedAction;
      } else {
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
  } else if (loopRaw != null) {
    warns.add('Invalid type for governance.loop_detection: "${loopRaw.runtimeType}" — using defaults');
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

  var enabled = defaults.enabled;
  final enabledRaw = canvasMap['enabled'];
  if (enabledRaw is bool) {
    enabled = enabledRaw;
  } else if (enabledRaw != null) {
    warns.add('Invalid type for canvas.enabled: "${enabledRaw.runtimeType}" — using default');
  }

  var share = defaults.share;
  final shareRaw = canvasMap['share'];
  if (shareRaw is Map) {
    final defaultPermissionRaw = shareRaw['default_permission'];
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
    final defaultTtlMinutes = _parseInt(
      'canvas.share.default_ttl',
      null,
      _parseDurationMinutes(shareRaw['default_ttl']),
      share.defaultTtlMinutes,
      warns,
    );
    final maxConnections = _parseInt(
      'canvas.share.max_connections',
      null,
      shareRaw['max_connections'],
      share.maxConnections,
      warns,
    );
    final autoShare = shareRaw['auto_share'] is bool ? shareRaw['auto_share'] as bool : share.autoShare;
    final showQr = shareRaw['show_qr'] is bool ? shareRaw['show_qr'] as bool : share.showQr;
    share = CanvasShareConfig(
      defaultPermission: defaultPermission,
      defaultTtlMinutes: defaultTtlMinutes,
      maxConnections: maxConnections,
      autoShare: autoShare,
      showQr: showQr,
    );
  } else if (shareRaw != null) {
    warns.add('Invalid type for canvas.share: "${shareRaw.runtimeType}" — using defaults');
  }

  var workshopMode = defaults.workshopMode;
  final workshopRaw = canvasMap['workshop_mode'];
  if (workshopRaw is Map) {
    workshopMode = CanvasWorkshopConfig(
      taskBoard: workshopRaw['task_board'] is bool ? workshopRaw['task_board'] as bool : workshopMode.taskBoard,
      showContributorStats: workshopRaw['show_contributor_stats'] is bool
          ? workshopRaw['show_contributor_stats'] as bool
          : workshopMode.showContributorStats,
      showBudgetBar: workshopRaw['show_budget_bar'] is bool
          ? workshopRaw['show_budget_bar'] as bool
          : workshopMode.showBudgetBar,
    );
  } else if (workshopRaw != null) {
    warns.add('Invalid type for canvas.workshop_mode: "${workshopRaw.runtimeType}" — using defaults');
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

  final convertedJobs = <Map<String, dynamic>>[
    for (final def in taskDefs) {'type': 'task', ...def.toJson()},
  ];

  return (convertedJobs: convertedJobs, taskDefs: taskDefs);
}

AlertsConfig _parseAlerts(Map<String, dynamic> yaml, AlertsConfig defaults, List<String> warns) {
  final alertsMap = _sectionMap('alerts', yaml, warns);
  if (alertsMap == null) return defaults;

  var enabled = defaults.enabled;
  final enabledRaw = alertsMap['enabled'];
  if (enabledRaw is bool) {
    enabled = enabledRaw;
  } else if (enabledRaw != null) {
    warns.add('Invalid type for alerts.enabled: "${enabledRaw.runtimeType}" — using default');
  }

  var cooldownSeconds = defaults.cooldownSeconds;
  final cooldownRaw = alertsMap['cooldown_seconds'];
  if (cooldownRaw is int && cooldownRaw >= 1) {
    cooldownSeconds = cooldownRaw;
  } else if (cooldownRaw is int) {
    warns.add('alerts.cooldown_seconds must be >= 1 — using default');
  } else if (cooldownRaw != null) {
    warns.add('Invalid type for alerts.cooldown_seconds: "${cooldownRaw.runtimeType}" — using default');
  }

  var burstThreshold = defaults.burstThreshold;
  final burstRaw = alertsMap['burst_threshold'];
  if (burstRaw is int && burstRaw >= 1) {
    burstThreshold = burstRaw;
  } else if (burstRaw is int) {
    warns.add('alerts.burst_threshold must be >= 1 — using default');
  } else if (burstRaw != null) {
    warns.add('Invalid type for alerts.burst_threshold: "${burstRaw.runtimeType}" — using default');
  }

  // Parse targets: list of {channel, recipient} maps
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

  // Parse routes: map of event-type-string -> list of target indices
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
