import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';

import '../config/channel_config_resolver.dart';
import '../config/config_load.dart';
import '../restart_service.dart';

final _log = Logger('ConfigApplyService');

/// The config file could not be read before a proposed write was judged.
final class ConfigReadException implements Exception {
  /// The failure the read raised.
  final Object cause;

  /// Creates a [ConfigReadException] value.
  const new(this.cause);

  @override
  String toString() => 'Failed to read config: $cause';
}

/// What one call to [ConfigApplyService.apply] did.
///
/// [errors] non-empty means nothing was written; [applied] and [pendingRestart]
/// are then both empty.
final class ConfigApplyResult {
  /// Fields refused by [ConfigValidator], in submission order.
  final List<ValidationError> errors;

  /// Fields that took effect during this call.
  final List<String> applied;

  /// Fields written to YAML that need a restart before they take effect.
  final List<String> pendingRestart;

  /// Creates a [ConfigApplyResult] value.
  const new({required this.errors, required this.applied, required this.pendingRestart});

  /// Whether the proposed update passed validation and was written.
  bool get isValid => errors.isEmpty;
}

/// The single authority for turning a proposed config update into a written,
/// applied change.
///
/// Both `PATCH /api/config` and the settings form go through it, so the two
/// tiers cannot disagree about what validates, what is written, or what
/// "applied" means. The sequence is fixed: validate → partition by
/// [ConfigMutability] → write every validated field → fire
/// [ConfigChangedEvent] for the live ones → [ConfigNotifier.reload] for the
/// reloadable ones (falling back to pending-restart on failure) → record
/// `restart.pending`.
final class ConfigApplyService {
  /// Creates a [ConfigApplyService] value.
  new({
    required this.writer,
    required this.validator,
    required this.dataDir,
    this.containerIsolationActive = false,
    this.eventBus,
    this.configNotifier,
  });

  /// Writer owning the YAML file this service persists through.
  final ConfigWriter writer;

  /// Validator both tiers share.
  final ConfigValidator validator;

  /// Data directory holding `restart.pending`.
  final String dataDir;

  /// Bus the live tier's [ConfigChangedEvent] is fired on.
  final EventBus? eventBus;

  /// Notifier the reloadable tier is applied through. Absent means every
  /// reloadable field is treated as restart-required.
  final ConfigNotifier? configNotifier;

  /// Whether this deployment actually isolates execution.
  ///
  /// The file cannot answer it: an absent `container:` section means "isolate
  /// if this host can", and the probe that settles it ran at startup.
  final bool containerIsolationActive;

  /// Loads the config as it currently stands on disk, carrying the posture in
  /// force rather than the one the file declares.
  ///
  /// Validation judges a submitted `execution: container` against what is
  /// actually running; re-reading the file alone would refuse it on an
  /// auto-isolating host with "container isolation is disabled".
  ///
  /// Throws [ConfigReadException] when the file cannot be read or parsed.
  DartclawConfig freshConfig() {
    try {
      final parsed = loadDartclawConfig(configPath: writer.configPath);
      return parsed.copyWith(container: parsed.container.resolved(enabled: containerIsolationActive));
    } catch (e) {
      throw ConfigReadException(e);
    }
  }

  /// Validates [updates], writes every validated field, and applies the ones
  /// that can take effect without a restart.
  ///
  /// [updates] maps dotted YAML paths to already-normalized values (see
  /// [normalizeConfigPatch]). Throws [ConfigReadException] when the current
  /// config cannot be read, [StateError] when the pre-write backup fails, and
  /// [FileSystemException] when the write itself fails.
  Future<ConfigApplyResult> apply(Map<String, dynamic> updates) async {
    final freshConfig = this.freshConfig();

    final errors = validator.validate(updates, currentValues: currentConfigValues(freshConfig));
    if (errors.isNotEmpty) {
      return ConfigApplyResult(errors: errors, applied: const [], pendingRestart: const []);
    }

    final liveFields = <String, dynamic>{};
    final reloadableFields = <String, dynamic>{};
    final restartFields = <String, dynamic>{};

    for (final entry in updates.entries) {
      final meta = ConfigMeta.fields[entry.key];
      if (meta == null) continue; // validated above — should not happen
      switch (meta.mutability) {
        case ConfigMutability.live:
          liveFields[entry.key] = entry.value;
        case ConfigMutability.reloadable:
          reloadableFields[entry.key] = entry.value;
        case ConfigMutability.restart:
        case ConfigMutability.readonly:
          restartFields[entry.key] = entry.value;
      }
    }

    // Write ALL validated fields to YAML (live, reloadable, and restart-required).
    // All fields must be persisted so they survive a restart.
    final allFields = {...liveFields, ...reloadableFields, ...restartFields};
    if (allFields.isNotEmpty) {
      await writer.updateFields(allFields);
    }

    // Fire ConfigChangedEvent only for live fields — Tier 1 subscribers handle
    // immediate side-effects. Reloadable fields are handled by ConfigNotifier.reload().
    if (liveFields.isNotEmpty) {
      eventBus?.fire(
        ConfigChangedEvent(
          changedKeys: liveFields.keys.toList(),
          oldValues: <String, dynamic>{},
          newValues: liveFields,
          requiresRestart: false,
          timestamp: DateTime.now(),
        ),
      );
    }

    // Apply reloadable fields via ConfigNotifier.reload() — reads fresh config
    // from disk after YAML write and notifies Reconfigurable services.
    // On failure, fall back to treating reloadable fields as pendingRestart.
    final reloadFallbackFields = <String, dynamic>{};
    if (reloadableFields.isNotEmpty) {
      final notifier = configNotifier;
      if (notifier == null) {
        // Not wired — treat as restart-required.
        reloadFallbackFields.addAll(reloadableFields);
      } else {
        try {
          notifier.reload(loadDartclawConfig(configPath: writer.configPath));
        } catch (e, st) {
          _log.severe('ConfigNotifier.reload() failed — falling back to pendingRestart for reloadable fields', e, st);
          reloadFallbackFields.addAll(reloadableFields);
        }
      }
    }

    final pendingRestartFields = {...restartFields, ...reloadFallbackFields};
    if (pendingRestartFields.isNotEmpty) {
      writeRestartPending(dataDir, pendingRestartFields.keys.toList());
    }

    final appliedFields = {...liveFields, ...reloadableFields}
      ..removeWhere((key, _) => reloadFallbackFields.containsKey(key));

    return ConfigApplyResult(
      errors: const [],
      applied: appliedFields.keys.toList(),
      pendingRestart: pendingRestartFields.keys.toList(),
    );
  }
}

/// The subset of current values [ConfigValidator]'s cross-field rules read.
Map<String, dynamic> currentConfigValues(DartclawConfig config) {
  final googleChatConfig = resolveChannelConfig<GoogleChatConfig>(config, ChannelType.googlechat);
  final audience = googleChatConfig.audience;
  GitHubWebhookConfig? githubConfig;
  try {
    githubConfig = config.extension<GitHubWebhookConfig>('github');
  } catch (_) {
    githubConfig = null; // Extension absent or malformed — omit GitHub fields from config view.
  }
  return {
    'governance.turn_limits.stall_timeout': config.governance.turnLimits.stallTimeout,
    'governance.turn_limits.turn_timeout': config.governance.turnLimits.turnTimeout,
    'channels.google_chat.enabled': googleChatConfig.enabled,
    'channels.google_chat.service_account': googleChatConfig.serviceAccount,
    'channels.google_chat.audience.type': switch (audience?.mode) {
      GoogleChatAudienceMode.appUrl => 'app-url',
      GoogleChatAudienceMode.projectNumber => 'project-number',
      null => null,
    },
    'channels.google_chat.audience.value': audience?.value,
    'channels.google_chat.dm_access': googleChatConfig.dmAccess.name,
    'channels.google_chat.group_access': googleChatConfig.groupAccess.name,
    'channels.google_chat.require_mention': googleChatConfig.requireMention,
    'github.enabled': githubConfig?.enabled,
    'github.webhook_secret': githubConfig?.webhookSecret,
    'github.webhook_path': githubConfig?.webhookPath,
  };
}

/// Expands the shorthands both config-writing tiers accept before validation.
///
/// A blank string on a nullable field becomes `null` (field removal), a
/// `provider/model` shorthand expands into the model plus its provider sibling
/// unless the caller set that sibling explicitly, and a task-trigger default
/// type is normalized to its canonical spelling.
Map<String, dynamic> normalizeConfigPatch(Map<String, dynamic> body) {
  final normalized = <String, dynamic>{};
  for (final entry in body.entries) {
    normalized.addAll(_normalizeConfigPatchEntry(entry.key, entry.value, body));
  }
  return normalized;
}

Map<String, dynamic> _normalizeConfigPatchEntry(String path, Object? value, Map<String, dynamic> rawBody) {
  final normalizedValue = _normalizeConfigPatchValue(path, value);
  final normalized = <String, dynamic>{path: normalizedValue};
  final providerPath = _providerSiblingPath(path);
  if (providerPath == null || rawBody.containsKey(providerPath) || normalizedValue is! String) {
    return normalized;
  }

  final shorthand = ProviderIdentity.parseProviderModelShorthand(normalizedValue);
  if (shorthand == null) {
    return normalized;
  }

  normalized[path] = shorthand.model;
  normalized[providerPath] = shorthand.provider;
  return normalized;
}

Object? _normalizeConfigPatchValue(String path, Object? value) {
  final meta = ConfigMeta.fields[path];
  if (meta != null && meta.nullable && value is String && value.trim().isEmpty) {
    return null;
  }
  return value;
}

String? _providerSiblingPath(String path) => switch (path) {
  'agent.model' => 'agent.provider',
  'workflow.defaults.workflow.model' => 'workflow.defaults.workflow.provider',
  'workflow.defaults.planner.model' => 'workflow.defaults.planner.provider',
  'workflow.defaults.executor.model' => 'workflow.defaults.executor.provider',
  'workflow.defaults.reviewer.model' => 'workflow.defaults.reviewer.provider',
  _ => null,
};
