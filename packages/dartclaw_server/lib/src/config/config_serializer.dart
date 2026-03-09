import 'package:dartclaw_core/dartclaw_core.dart';

import '../runtime_config.dart';
import 'config_meta.dart';

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
    return {
      'port': config.port,
      'host': config.host,
      'name': config.name,
      'dataDir': config.dataDir,
      'workerTimeout': config.workerTimeout,
      'memoryMaxBytes': config.memoryMaxBytes,
      'agent': {'model': config.agentModel, 'maxTurns': config.agentMaxTurns, 'context1m': config.agentContext1m},
      'concurrency': {'maxParallelTurns': config.maxParallelTurns},
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
          'enabled': config.channelConfig.channelConfigs['whatsapp']?['enabled'] ?? false,
          'dmAccess': config.channelConfig.channelConfigs['whatsapp']?['dm_access'] ?? 'pairing',
          'groupAccess': config.channelConfig.channelConfigs['whatsapp']?['group_access'] ?? 'disabled',
          'requireMention': config.channelConfig.channelConfigs['whatsapp']?['require_mention'] ?? true,
        },
        'signal': {
          'enabled': config.channelConfig.channelConfigs['signal']?['enabled'] ?? false,
          'dmAccess': config.channelConfig.channelConfigs['signal']?['dm_access'] ?? 'allowlist',
          'groupAccess': config.channelConfig.channelConfigs['signal']?['group_access'] ?? 'disabled',
          'requireMention': config.channelConfig.channelConfigs['signal']?['require_mention'] ?? true,
        },
      },
      'gateway': {
        'authMode': config.gatewayAuthMode,
        'token': config.gatewayToken != null ? '***' : null,
        'hsts': config.gatewayHsts,
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
  };
}
