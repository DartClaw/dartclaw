import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

import '../runtime_config.dart';

/// Converts [DartclawConfig] to the structured JSON shape returned by
/// `GET /api/config`.
///
/// Live-mutable fields are read from [RuntimeConfig] (current runtime state)
/// rather than [DartclawConfig] (startup YAML) so the UI reflects toggle
/// changes without restart.
class ConfigSerializer {
  const ConfigSerializer();

  /// Serializes the full config to the nested camelCase JSON shape.
  ///
  /// [config] provides startup-time values and defaults.
  /// [runtime] provides current toggle state for live-mutable fields.
  Map<String, dynamic> toJson(DartclawConfig config, {required RuntimeConfig runtime}) {
    ensureDartclawGoogleChatRegistered();
    ensureDartclawSignalRegistered();
    ensureDartclawWhatsappRegistered();

    final googleChatConfig = config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);
    final signalConfig = config.getChannelConfig<SignalConfig>(ChannelType.signal);
    final whatsAppConfig = config.getChannelConfig<WhatsAppConfig>(ChannelType.whatsapp);
    return {
      'port': config.server.port,
      'host': config.server.host,
      'name': config.server.name,
      'dataDir': config.server.dataDir,
      'baseUrl': config.server.baseUrl,
      'workerTimeout': config.server.workerTimeout,
      'memoryMaxBytes': config.memory.maxBytes,
      'agent': {'model': config.agent.model, 'effort': config.agent.effort, 'maxTurns': config.agent.maxTurns},
      'advisor': {
        'enabled': config.advisor.enabled,
        'model': config.advisor.model,
        'effort': config.advisor.effort,
        'triggers': config.advisor.triggers,
        'periodicIntervalMinutes': config.advisor.periodicIntervalMinutes,
        'maxWindowTurns': config.advisor.maxWindowTurns,
        'maxPriorReflections': config.advisor.maxPriorReflections,
      },
      'auth': {'cookieSecure': config.auth.cookieSecure, 'trustedProxies': config.auth.trustedProxies},
      'concurrency': {'maxParallelTurns': config.server.maxParallelTurns},
      'guardAudit': {'maxRetentionDays': config.security.guardAuditMaxRetentionDays},
      'tasks': {
        'maxConcurrent': config.tasks.maxConcurrent,
        'artifactRetentionDays': config.tasks.artifactRetentionDays,
        'completionAction': config.tasks.completionAction,
        'worktree': {
          'baseRef': config.tasks.worktreeBaseRef,
          'staleTimeoutHours': config.tasks.worktreeStaleTimeoutHours,
          'mergeStrategy': config.tasks.worktreeMergeStrategy,
        },
      },
      'sessions': {
        'resetHour': config.sessions.resetHour,
        'idleTimeoutMinutes': config.sessions.idleTimeoutMinutes,
        'dmScope': config.sessions.scopeConfig.dmScope.toYaml(),
        'groupScope': config.sessions.scopeConfig.groupScope.toYaml(),
        'model': config.sessions.scopeConfig.model,
        'effort': config.sessions.scopeConfig.effort,
        'channels': {
          for (final entry in config.sessions.scopeConfig.channels.entries)
            entry.key: {
              if (entry.value.dmScope != null) 'dmScope': entry.value.dmScope!.toYaml(),
              if (entry.value.groupScope != null) 'groupScope': entry.value.groupScope!.toYaml(),
              if (entry.value.model != null) 'model': entry.value.model,
              if (entry.value.effort != null) 'effort': entry.value.effort,
            },
        },
        'maintenance': {
          'mode': config.sessions.maintenanceConfig.mode.toYaml(),
          'pruneAfterDays': config.sessions.maintenanceConfig.pruneAfterDays,
          'maxSessions': config.sessions.maintenanceConfig.maxSessions,
          'maxDiskMb': config.sessions.maintenanceConfig.maxDiskMb,
          'cronRetentionHours': config.sessions.maintenanceConfig.cronRetentionHours,
          'schedule': config.sessions.maintenanceConfig.schedule,
        },
      },
      'logging': {'level': config.logging.level, 'format': config.logging.format},
      'scheduling': {
        'heartbeat': {
          // Live-mutable: read from RuntimeConfig
          'enabled': runtime.heartbeatEnabled,
          'intervalMinutes': config.scheduling.heartbeatIntervalMinutes,
        },
        'jobs': config.scheduling.jobs,
      },
      'context': {
        'reserveTokens': config.context.reserveTokens,
        'maxResultBytes': config.context.maxResultBytes,
        'warningThreshold': config.context.warningThreshold,
        'explorationSummaryThreshold': config.context.explorationSummaryThreshold,
        'compactInstructions': config.context.compactInstructions,
        'identifierPreservation': config.context.identifierPreservation,
        'identifierInstructions': config.context.identifierInstructions,
      },
      'search': {'backend': config.search.backend},
      'guards': {
        'content': {
          'enabled': config.security.contentGuardEnabled,
          'classifier': config.security.contentGuardClassifier,
          'model': config.security.contentGuardModel,
          'maxBytes': config.security.contentGuardMaxBytes,
        },
        'inputSanitizer': {
          'enabled': config.security.inputSanitizerEnabled,
          'channelsOnly': config.security.inputSanitizerChannelsOnly,
        },
      },
      'memory': {
        'maxBytes': config.memory.maxBytes,
        'pruning': {
          'enabled': config.memory.pruningEnabled,
          'archiveAfterDays': config.memory.archiveAfterDays,
          'schedule': config.memory.pruningSchedule,
        },
      },
      'usage': {
        'budgetWarningTokens': config.usage.budgetWarningTokens,
        'maxFileSizeBytes': config.usage.maxFileSizeBytes,
      },
      'workspace': {
        'gitSync': {
          // Live-mutable: read from RuntimeConfig
          'enabled': runtime.gitSyncEnabled,
          'pushEnabled': runtime.gitSyncPushEnabled,
        },
      },
      'canvas': {
        'enabled': config.canvas.enabled,
        'share': {
          'defaultPermission': config.canvas.share.defaultPermission,
          'defaultTtlMinutes': config.canvas.share.defaultTtlMinutes,
          'maxConnections': config.canvas.share.maxConnections,
          'autoShare': config.canvas.share.autoShare,
          'showQr': config.canvas.share.showQr,
        },
        'workshopMode': {
          'taskBoard': config.canvas.workshopMode.taskBoard,
          'showContributorStats': config.canvas.workshopMode.showContributorStats,
          'showBudgetBar': config.canvas.workshopMode.showBudgetBar,
        },
      },
      'channels': {
        'whatsapp': {
          'enabled': whatsAppConfig.enabled,
          'dmAccess': whatsAppConfig.dmAccess.name,
          'groupAccess': whatsAppConfig.groupAccess.name,
          'requireMention': whatsAppConfig.requireMention,
          'taskTrigger': _taskTriggerJson(whatsAppConfig.taskTrigger),
        },
        'signal': {
          'enabled': signalConfig.enabled,
          'dmAccess': signalConfig.dmAccess.name,
          'groupAccess': signalConfig.groupAccess.name,
          'requireMention': signalConfig.requireMention,
          'taskTrigger': _taskTriggerJson(signalConfig.taskTrigger),
        },
        'googleChat': {
          'enabled': googleChatConfig.enabled,
          'serviceAccount': _serializeGoogleServiceAccount(googleChatConfig.serviceAccount),
          'oauthCredentials': googleChatConfig.oauthCredentials != null,
          'audience': googleChatConfig.audience == null
              ? null
              : {
                  'type': _googleChatAudienceMode(googleChatConfig.audience!.mode),
                  'value': googleChatConfig.audience!.value,
                },
          'webhookPath': googleChatConfig.webhookPath,
          'botUser': googleChatConfig.botUser,
          'typingIndicator': googleChatConfig.typingIndicatorMode.name,
          'quoteReplyMode': googleChatConfig.quoteReplyMode.name,
          'reactionsAuth': googleChatConfig.reactionsAuth.name,
          'feedback': {
            'enabled': googleChatConfig.feedback.enabled,
            'minFeedbackDelay': _durationString(googleChatConfig.feedback.minFeedbackDelay),
            'statusInterval': _durationString(googleChatConfig.feedback.statusInterval),
            'statusStyle': googleChatConfig.feedback.statusStyle.name,
          },
          'dmAccess': googleChatConfig.dmAccess.name,
          'dmAllowlist': googleChatConfig.dmAllowlist,
          'groupAccess': googleChatConfig.groupAccess.name,
          'groupAllowlist': googleChatConfig.groupIds,
          'requireMention': googleChatConfig.requireMention,
          'taskTrigger': _taskTriggerJson(googleChatConfig.taskTrigger),
        },
      },
      'gateway': {
        'authMode': config.gateway.authMode,
        'token': config.gateway.token != null ? '***' : null,
        'hsts': config.gateway.hsts,
      },
      'governance': {
        'adminSenders': config.governance.adminSenders,
        'queueStrategy': config.governance.queueStrategy.name,
        'crowdCoding': {'model': config.governance.crowdCoding.model, 'effort': config.governance.crowdCoding.effort},
        'turnProgress': {
          'stallTimeout': _durationString(config.governance.turnProgress.stallTimeout),
          'stallAction': config.governance.turnProgress.stallAction.name,
        },
        'rateLimits': {
          'perSender': {
            'messages': config.governance.rateLimits.perSender.messages,
            'window': config.governance.rateLimits.perSender.windowMinutes,
            'maxQueued': config.governance.rateLimits.perSender.maxQueued,
            'maxPauseQueued': config.governance.rateLimits.perSender.maxPauseQueued,
          },
          'global': {
            'turns': config.governance.rateLimits.global.turns,
            'window': config.governance.rateLimits.global.windowMinutes,
          },
        },
        'budget': {
          'dailyTokens': config.governance.budget.dailyTokens,
          'action': config.governance.budget.action.name,
          'timezone': config.governance.budget.timezone,
        },
        'loopDetection': {
          'enabled': config.governance.loopDetection.enabled,
          'maxConsecutiveTurns': config.governance.loopDetection.maxConsecutiveTurns,
          'maxTokensPerMinute': config.governance.loopDetection.maxTokensPerMinute,
          'velocityWindowMinutes': config.governance.loopDetection.velocityWindowMinutes,
          'maxConsecutiveIdenticalToolCalls': config.governance.loopDetection.maxConsecutiveIdenticalToolCalls,
          'action': config.governance.loopDetection.action.name,
        },
      },
      'alerts': {
        'enabled': config.alerts.enabled,
        'cooldownSeconds': config.alerts.cooldownSeconds,
        'burstThreshold': config.alerts.burstThreshold,
        'targets': [
          for (final t in config.alerts.targets) {'channel': t.channel, 'recipient': t.recipient},
        ],
        'routes': config.alerts.routes,
      },
    };
  }

  /// Serializes [ConfigMeta.fields] to the `_meta.fields` shape.
  ///
  /// Each entry includes mutability, type, and any constraints (min, max,
  /// allowedValues, nullable).
  Map<String, dynamic> metaJson() {
    final result = <String, dynamic>{};
    for (final entry in ConfigMeta.fields.entries) {
      final f = entry.value;
      final fieldMap = <String, dynamic>{'mutable': f.mutability.name, 'type': _typeLabel(f.type)};
      if (f.min != null) fieldMap['min'] = f.min;
      if (f.max != null) fieldMap['max'] = f.max;
      if (f.allowedValues != null) fieldMap['allowedValues'] = f.allowedValues;
      if (f.nullable) fieldMap['nullable'] = true;
      result[f.yamlPath] = fieldMap;
    }
    return result;
  }

  static String _typeLabel(ConfigFieldType type) => switch (type) {
    ConfigFieldType.int_ => 'int',
    ConfigFieldType.string => 'string',
    ConfigFieldType.bool_ => 'bool',
    ConfigFieldType.enum_ => 'enum',
    ConfigFieldType.stringList => 'string[]',
  };

  static String _googleChatAudienceMode(GoogleChatAudienceMode mode) => switch (mode) {
    GoogleChatAudienceMode.appUrl => 'app-url',
    GoogleChatAudienceMode.projectNumber => 'project-number',
  };

  static String? _serializeGoogleServiceAccount(String? serviceAccount) {
    final normalized = serviceAccount?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (!normalized.startsWith('{')) {
      return normalized;
    }

    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map<String, dynamic>) {
        final clientEmail = decoded['client_email'];
        if (clientEmail is String && clientEmail.trim().isNotEmpty) {
          return clientEmail.trim();
        }
      }
    } catch (e) {
      // Fall through to a generic redaction marker for malformed inline JSON.
    }

    return '***';
  }

  static Map<String, dynamic> _taskTriggerJson(TaskTriggerConfig config) => {
    'enabled': config.enabled,
    'prefix': config.prefix,
    'defaultType': config.defaultType,
    'autoStart': config.autoStart,
  };

  static String _durationString(Duration duration) => '${duration.inSeconds}s';
}
