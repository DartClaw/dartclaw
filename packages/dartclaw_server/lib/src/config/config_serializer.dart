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
      'workerTimeout': config.server.workerTimeout,
      'memoryMaxBytes': config.memory.maxBytes,
      'agent': {'model': config.agent.model, 'effort': config.agent.effort, 'maxTurns': config.agent.maxTurns},
      'auth': {'cookieSecure': config.auth.cookieSecure, 'trustedProxies': config.auth.trustedProxies},
      'concurrency': {'maxParallelTurns': config.server.maxParallelTurns},
      'guardAudit': {'maxRetentionDays': config.security.guardAuditMaxRetentionDays},
      'tasks': {
        'maxConcurrent': config.tasks.maxConcurrent,
        'artifactRetentionDays': config.tasks.artifactRetentionDays,
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
        'channels': {
          for (final entry in config.sessions.scopeConfig.channels.entries)
            entry.key: {
              if (entry.value.dmScope != null) 'dmScope': entry.value.dmScope!.toYaml(),
              if (entry.value.groupScope != null) 'groupScope': entry.value.groupScope!.toYaml(),
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
        'authMode': config.gateway.authMode,
        'token': config.gateway.token != null ? '***' : null,
        'hsts': config.gateway.hsts,
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
}
