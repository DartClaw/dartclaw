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
      'port': config.port,
      'host': config.host,
      'name': config.name,
      'dataDir': config.dataDir,
      'workerTimeout': config.workerTimeout,
      'memoryMaxBytes': config.memoryMaxBytes,
      'agent': {'model': config.agentModel, 'maxTurns': config.agentMaxTurns, 'context1m': config.agentContext1m},
      'auth': {'cookieSecure': config.cookieSecure, 'trustedProxies': config.trustedProxies},
      'concurrency': {'maxParallelTurns': config.maxParallelTurns},
      'guardAudit': {'maxRetentionDays': config.guardAuditMaxRetentionDays},
      'tasks': {
        'maxConcurrent': config.tasksMaxConcurrent,
        'artifactRetentionDays': config.tasksArtifactRetentionDays,
        'worktree': {
          'baseRef': config.tasksWorktreeBaseRef,
          'staleTimeoutHours': config.tasksWorktreeStaleTimeoutHours,
          'mergeStrategy': config.tasksWorktreeMergeStrategy,
        },
      },
      'sessions': {
        'resetHour': config.sessionResetHour,
        'idleTimeoutMinutes': config.sessionIdleTimeoutMinutes,
        'dmScope': config.sessionScopeConfig.dmScope.toYaml(),
        'groupScope': config.sessionScopeConfig.groupScope.toYaml(),
        'channels': {
          for (final entry in config.sessionScopeConfig.channels.entries)
            entry.key: {
              if (entry.value.dmScope != null) 'dmScope': entry.value.dmScope!.toYaml(),
              if (entry.value.groupScope != null) 'groupScope': entry.value.groupScope!.toYaml(),
            },
        },
        'maintenance': {
          'mode': config.sessionMaintenanceConfig.mode.toYaml(),
          'pruneAfterDays': config.sessionMaintenanceConfig.pruneAfterDays,
          'maxSessions': config.sessionMaintenanceConfig.maxSessions,
          'maxDiskMb': config.sessionMaintenanceConfig.maxDiskMb,
          'cronRetentionHours': config.sessionMaintenanceConfig.cronRetentionHours,
          'schedule': config.sessionMaintenanceConfig.schedule,
        },
      },
      'logging': {'level': config.logLevel, 'format': config.logFormat},
      'scheduling': {
        'heartbeat': {
          // Live-mutable: read from RuntimeConfig
          'enabled': runtime.heartbeatEnabled,
          'intervalMinutes': config.heartbeatIntervalMinutes,
        },
        'jobs': config.schedulingJobs,
      },
      'context': {'reserveTokens': config.contextReserveTokens, 'maxResultBytes': config.contextMaxResultBytes},
      'search': {'backend': config.searchBackend},
      'guards': {
        'content': {
          'enabled': config.contentGuardEnabled,
          'classifier': config.contentGuardClassifier,
          'model': config.contentGuardModel,
          'maxBytes': config.contentGuardMaxBytes,
        },
        'inputSanitizer': {'enabled': config.inputSanitizerEnabled, 'channelsOnly': config.inputSanitizerChannelsOnly},
      },
      'memory': {
        'maxBytes': config.memoryMaxBytes,
        'pruning': {
          'enabled': config.memoryPruningEnabled,
          'archiveAfterDays': config.memoryArchiveAfterDays,
          'schedule': config.memoryPruningSchedule,
        },
      },
      'usage': {
        'budgetWarningTokens': config.usageBudgetWarningTokens,
        'maxFileSizeBytes': config.usageMaxFileSizeBytes,
      },
      'workspace': {
        'gitSync': {
          // Live-mutable: read from RuntimeConfig
          'enabled': runtime.gitSyncEnabled,
          'pushEnabled': runtime.gitSyncPushEnabled,
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
          'audience': googleChatConfig.audience == null
              ? null
              : {
                  'type': _googleChatAudienceMode(googleChatConfig.audience!.mode),
                  'value': googleChatConfig.audience!.value,
                },
          'webhookPath': googleChatConfig.webhookPath,
          'botUser': googleChatConfig.botUser,
          'typingIndicator': googleChatConfig.typingIndicator,
          'dmAccess': googleChatConfig.dmAccess.name,
          'dmAllowlist': googleChatConfig.dmAllowlist,
          'groupAccess': googleChatConfig.groupAccess.name,
          'groupAllowlist': googleChatConfig.groupAllowlist,
          'requireMention': googleChatConfig.requireMention,
          'taskTrigger': _taskTriggerJson(googleChatConfig.taskTrigger),
        },
      },
      'gateway': {
        'authMode': config.gatewayAuthMode,
        'token': config.gatewayToken != null ? '***' : null,
        'hsts': config.gatewayHsts,
      },
      'automation': {
        'scheduledTasks': config.automationScheduledTasks
            .map(
              (d) => {
                'id': d.id,
                'cronExpression': d.cronExpression,
                'enabled': d.enabled,
                'title': d.title,
                'description': d.description,
                'type': d.type.name,
                'acceptanceCriteria': d.acceptanceCriteria,
                'autoStart': d.autoStart,
              },
            )
            .toList(),
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
    } catch (_) {
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
}
