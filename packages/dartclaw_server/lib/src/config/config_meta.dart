/// Mutability classification for config fields.
enum ConfigMutability {
  /// Takes effect immediately via Tier 1 service APIs.
  live,

  /// Written to YAML, applied on next startup.
  restart,

  /// Visible but not editable via API.
  readonly,
}

/// Type of a config field.
enum ConfigFieldType { int_, string, bool_, enum_, stringList }

/// Metadata describing a single config field.
class FieldMeta {
  /// Dot-separated YAML path (e.g., `'scheduling.heartbeat.interval_minutes'`).
  final String yamlPath;

  /// CamelCase JSON key for API responses (e.g., `'scheduling.heartbeat.intervalMinutes'`).
  final String jsonKey;

  final ConfigFieldType type;
  final ConfigMutability mutability;

  /// Whether `null` is a valid value (field removal).
  final bool nullable;

  /// For [ConfigFieldType.int_]: minimum allowed value (inclusive).
  final int? min;

  /// For [ConfigFieldType.int_]: maximum allowed value (inclusive).
  final int? max;

  /// For [ConfigFieldType.enum_]: allowed string values.
  final List<String>? allowedValues;

  const FieldMeta({
    required this.yamlPath,
    required this.jsonKey,
    required this.type,
    required this.mutability,
    this.nullable = false,
    this.min,
    this.max,
    this.allowedValues,
  });
}

/// Static registry of all config field metadata.
///
/// Centralizes field definitions, mutability classification, type constraints,
/// and the canonical YAML-path-to-JSON-key mapping. Used by [ConfigValidator]
/// for validation and by the config API (S04) for `_meta.fields` responses.
abstract final class ConfigMeta {
  /// All registered fields keyed by YAML path.
  static const Map<String, FieldMeta> fields = {
    // --- Live-mutable fields (3) ---
    'scheduling.heartbeat.enabled': FieldMeta(
      yamlPath: 'scheduling.heartbeat.enabled',
      jsonKey: 'scheduling.heartbeat.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.live,
    ),
    'workspace.git_sync.enabled': FieldMeta(
      yamlPath: 'workspace.git_sync.enabled',
      jsonKey: 'workspace.gitSync.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.live,
    ),
    'workspace.git_sync.push_enabled': FieldMeta(
      yamlPath: 'workspace.git_sync.push_enabled',
      jsonKey: 'workspace.gitSync.pushEnabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.live,
    ),

    // --- Restart-required fields ---

    // Top-level scalars
    'port': FieldMeta(
      yamlPath: 'port',
      jsonKey: 'port',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 65535,
    ),
    'host': FieldMeta(
      yamlPath: 'host',
      jsonKey: 'host',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'name': FieldMeta(
      yamlPath: 'name',
      jsonKey: 'name',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'data_dir': FieldMeta(
      yamlPath: 'data_dir',
      jsonKey: 'dataDir',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'worker_timeout': FieldMeta(
      yamlPath: 'worker_timeout',
      jsonKey: 'workerTimeout',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'memory_max_bytes': FieldMeta(
      yamlPath: 'memory_max_bytes',
      jsonKey: 'memoryMaxBytes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),

    // Agent
    'agent.model': FieldMeta(
      yamlPath: 'agent.model',
      jsonKey: 'agent.model',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'agent.max_turns': FieldMeta(
      yamlPath: 'agent.max_turns',
      jsonKey: 'agent.maxTurns',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      nullable: true,
      min: 1,
    ),
    'agent.context_1m': FieldMeta(
      yamlPath: 'agent.context_1m',
      jsonKey: 'agent.context1m',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'auth.cookie_secure': FieldMeta(
      yamlPath: 'auth.cookie_secure',
      jsonKey: 'auth.cookieSecure',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'auth.trusted_proxies': FieldMeta(
      yamlPath: 'auth.trusted_proxies',
      jsonKey: 'auth.trustedProxies',
      type: ConfigFieldType.stringList,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),

    // Tasks
    'tasks.max_concurrent': FieldMeta(
      yamlPath: 'tasks.max_concurrent',
      jsonKey: 'tasks.maxConcurrent',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 10,
    ),

    'tasks.worktree.base_ref': FieldMeta(
      yamlPath: 'tasks.worktree.base_ref',
      jsonKey: 'tasks.worktree.baseRef',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'tasks.worktree.stale_timeout_hours': FieldMeta(
      yamlPath: 'tasks.worktree.stale_timeout_hours',
      jsonKey: 'tasks.worktree.staleTimeoutHours',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 168,
    ),
    'tasks.worktree.merge_strategy': FieldMeta(
      yamlPath: 'tasks.worktree.merge_strategy',
      jsonKey: 'tasks.worktree.mergeStrategy',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      allowedValues: ['squash', 'merge'],
    ),

    // Concurrency
    'concurrency.max_parallel_turns': FieldMeta(
      yamlPath: 'concurrency.max_parallel_turns',
      jsonKey: 'concurrency.maxParallelTurns',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 10,
    ),
    'guard_audit.max_entries': FieldMeta(
      yamlPath: 'guard_audit.max_entries',
      jsonKey: 'guardAudit.maxEntries',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 100,
      max: 1000000,
    ),

    // Sessions
    'sessions.reset_hour': FieldMeta(
      yamlPath: 'sessions.reset_hour',
      jsonKey: 'sessions.resetHour',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
      max: 23,
    ),
    'sessions.idle_timeout_minutes': FieldMeta(
      yamlPath: 'sessions.idle_timeout_minutes',
      jsonKey: 'sessions.idleTimeoutMinutes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'sessions.dm_scope': FieldMeta(
      yamlPath: 'sessions.dm_scope',
      jsonKey: 'sessions.dmScope',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.live,
      allowedValues: ['shared', 'per-contact', 'per-channel-contact'],
    ),
    'sessions.group_scope': FieldMeta(
      yamlPath: 'sessions.group_scope',
      jsonKey: 'sessions.groupScope',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.live,
      allowedValues: ['shared', 'per-member'],
    ),

    // Sessions — maintenance
    'sessions.maintenance.mode': FieldMeta(
      yamlPath: 'sessions.maintenance.mode',
      jsonKey: 'sessions.maintenance.mode',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['warn', 'enforce'],
    ),
    'sessions.maintenance.prune_after_days': FieldMeta(
      yamlPath: 'sessions.maintenance.prune_after_days',
      jsonKey: 'sessions.maintenance.pruneAfterDays',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'sessions.maintenance.max_sessions': FieldMeta(
      yamlPath: 'sessions.maintenance.max_sessions',
      jsonKey: 'sessions.maintenance.maxSessions',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'sessions.maintenance.max_disk_mb': FieldMeta(
      yamlPath: 'sessions.maintenance.max_disk_mb',
      jsonKey: 'sessions.maintenance.maxDiskMb',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'sessions.maintenance.cron_retention_hours': FieldMeta(
      yamlPath: 'sessions.maintenance.cron_retention_hours',
      jsonKey: 'sessions.maintenance.cronRetentionHours',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'sessions.maintenance.schedule': FieldMeta(
      yamlPath: 'sessions.maintenance.schedule',
      jsonKey: 'sessions.maintenance.schedule',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),

    // Logging
    'logging.level': FieldMeta(
      yamlPath: 'logging.level',
      jsonKey: 'logging.level',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['FINE', 'INFO', 'WARNING', 'SEVERE'],
    ),
    'logging.format': FieldMeta(
      yamlPath: 'logging.format',
      jsonKey: 'logging.format',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['human', 'json'],
    ),

    // Scheduling / heartbeat
    'scheduling.heartbeat.interval_minutes': FieldMeta(
      yamlPath: 'scheduling.heartbeat.interval_minutes',
      jsonKey: 'scheduling.heartbeat.intervalMinutes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 1440,
    ),

    // Context
    'context.reserve_tokens': FieldMeta(
      yamlPath: 'context.reserve_tokens',
      jsonKey: 'context.reserveTokens',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'context.max_result_bytes': FieldMeta(
      yamlPath: 'context.max_result_bytes',
      jsonKey: 'context.maxResultBytes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),

    // Search
    'search.backend': FieldMeta(
      yamlPath: 'search.backend',
      jsonKey: 'search.backend',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['fts5', 'qmd'],
    ),

    // Guards (flat settings — writable, restart-required)
    'guards.content.enabled': FieldMeta(
      yamlPath: 'guards.content.enabled',
      jsonKey: 'guards.content.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'guards.content.classifier': FieldMeta(
      yamlPath: 'guards.content.classifier',
      jsonKey: 'guards.content.classifier',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['claude_binary', 'anthropic_api'],
    ),
    'guards.content.model': FieldMeta(
      yamlPath: 'guards.content.model',
      jsonKey: 'guards.content.model',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'guards.content.max_bytes': FieldMeta(
      yamlPath: 'guards.content.max_bytes',
      jsonKey: 'guards.content.maxBytes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'guards.input_sanitizer.enabled': FieldMeta(
      yamlPath: 'guards.input_sanitizer.enabled',
      jsonKey: 'guards.inputSanitizer.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'guards.input_sanitizer.channels_only': FieldMeta(
      yamlPath: 'guards.input_sanitizer.channels_only',
      jsonKey: 'guards.inputSanitizer.channelsOnly',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),

    // Memory pruning
    'memory.pruning.enabled': FieldMeta(
      yamlPath: 'memory.pruning.enabled',
      jsonKey: 'memory.pruning.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'memory.pruning.archive_after_days': FieldMeta(
      yamlPath: 'memory.pruning.archive_after_days',
      jsonKey: 'memory.pruning.archiveAfterDays',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'memory.pruning.schedule': FieldMeta(
      yamlPath: 'memory.pruning.schedule',
      jsonKey: 'memory.pruning.schedule',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),

    // Usage
    'usage.budget_warning_tokens': FieldMeta(
      yamlPath: 'usage.budget_warning_tokens',
      jsonKey: 'usage.budgetWarningTokens',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      nullable: true,
      min: 1,
    ),
    'usage.max_file_size_bytes': FieldMeta(
      yamlPath: 'usage.max_file_size_bytes',
      jsonKey: 'usage.maxFileSizeBytes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),

    // Channels — WhatsApp
    'channels.whatsapp.dm_access': FieldMeta(
      yamlPath: 'channels.whatsapp.dm_access',
      jsonKey: 'channels.whatsapp.dmAccess',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['open', 'disabled', 'allowlist', 'pairing'],
    ),
    'channels.whatsapp.group_access': FieldMeta(
      yamlPath: 'channels.whatsapp.group_access',
      jsonKey: 'channels.whatsapp.groupAccess',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['open', 'disabled', 'allowlist'],
    ),
    'channels.whatsapp.require_mention': FieldMeta(
      yamlPath: 'channels.whatsapp.require_mention',
      jsonKey: 'channels.whatsapp.requireMention',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),

    // Channels — Signal
    'channels.signal.dm_access': FieldMeta(
      yamlPath: 'channels.signal.dm_access',
      jsonKey: 'channels.signal.dmAccess',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['open', 'disabled', 'allowlist', 'pairing'],
    ),
    'channels.signal.group_access': FieldMeta(
      yamlPath: 'channels.signal.group_access',
      jsonKey: 'channels.signal.groupAccess',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['open', 'disabled', 'allowlist'],
    ),
    'channels.signal.require_mention': FieldMeta(
      yamlPath: 'channels.signal.require_mention',
      jsonKey: 'channels.signal.requireMention',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),

    // Channels — Google Chat
    'channels.google_chat.enabled': FieldMeta(
      yamlPath: 'channels.google_chat.enabled',
      jsonKey: 'channels.googleChat.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.service_account': FieldMeta(
      yamlPath: 'channels.google_chat.service_account',
      jsonKey: 'channels.googleChat.serviceAccount',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.readonly,
      nullable: true,
    ),
    'channels.google_chat.audience.type': FieldMeta(
      yamlPath: 'channels.google_chat.audience.type',
      jsonKey: 'channels.googleChat.audience.type',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.readonly,
      nullable: true,
      allowedValues: ['app-url', 'project-number'],
    ),
    'channels.google_chat.audience.value': FieldMeta(
      yamlPath: 'channels.google_chat.audience.value',
      jsonKey: 'channels.googleChat.audience.value',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.readonly,
      nullable: true,
    ),
    'channels.google_chat.webhook_path': FieldMeta(
      yamlPath: 'channels.google_chat.webhook_path',
      jsonKey: 'channels.googleChat.webhookPath',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.bot_user': FieldMeta(
      yamlPath: 'channels.google_chat.bot_user',
      jsonKey: 'channels.googleChat.botUser',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'channels.google_chat.typing_indicator': FieldMeta(
      yamlPath: 'channels.google_chat.typing_indicator',
      jsonKey: 'channels.googleChat.typingIndicator',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.dm_access': FieldMeta(
      yamlPath: 'channels.google_chat.dm_access',
      jsonKey: 'channels.googleChat.dmAccess',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['open', 'disabled', 'allowlist', 'pairing'],
    ),
    'channels.google_chat.dm_allowlist': FieldMeta(
      yamlPath: 'channels.google_chat.dm_allowlist',
      jsonKey: 'channels.googleChat.dmAllowlist',
      type: ConfigFieldType.stringList,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'channels.google_chat.group_access': FieldMeta(
      yamlPath: 'channels.google_chat.group_access',
      jsonKey: 'channels.googleChat.groupAccess',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['open', 'disabled', 'allowlist'],
    ),
    'channels.google_chat.group_allowlist': FieldMeta(
      yamlPath: 'channels.google_chat.group_allowlist',
      jsonKey: 'channels.googleChat.groupAllowlist',
      type: ConfigFieldType.stringList,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'channels.google_chat.require_mention': FieldMeta(
      yamlPath: 'channels.google_chat.require_mention',
      jsonKey: 'channels.googleChat.requireMention',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),

    // Automation — scheduled tasks (restart-required, list type)
    // Individual entries validated during parsing — registered as a section marker.

    // --- Read-only fields ---
    'gateway.auth_mode': FieldMeta(
      yamlPath: 'gateway.auth_mode',
      jsonKey: 'gateway.authMode',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.readonly,
    ),
    'gateway.token': FieldMeta(
      yamlPath: 'gateway.token',
      jsonKey: 'gateway.token',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.readonly,
    ),
    'gateway.hsts': FieldMeta(
      yamlPath: 'gateway.hsts',
      jsonKey: 'gateway.hsts',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
  };

  static Map<String, FieldMeta>? _byJsonKey;

  /// All registered fields keyed by JSON key.
  static Map<String, FieldMeta> get byJsonKey {
    return _byJsonKey ??= {for (final f in fields.values) f.jsonKey: f};
  }

  /// Returns fields matching the given [mutability].
  static Iterable<FieldMeta> forMutability(ConfigMutability mutability) {
    return fields.values.where((f) => f.mutability == mutability);
  }

  /// Whether [yamlPath] is a known config field.
  static bool isKnown(String yamlPath) => fields.containsKey(yamlPath);

  /// Whether [yamlPath] exists and is not [ConfigMutability.readonly].
  static bool isWritable(String yamlPath) {
    final meta = fields[yamlPath];
    return meta != null && meta.mutability != ConfigMutability.readonly;
  }
}
