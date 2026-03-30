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
    'base_url': FieldMeta(
      yamlPath: 'base_url',
      jsonKey: 'baseUrl',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'data_dir': FieldMeta(
      yamlPath: 'data_dir',
      jsonKey: 'dataDir',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'source_dir': FieldMeta(
      yamlPath: 'source_dir',
      jsonKey: 'sourceDir',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'static_dir': FieldMeta(
      yamlPath: 'static_dir',
      jsonKey: 'staticDir',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'templates_dir': FieldMeta(
      yamlPath: 'templates_dir',
      jsonKey: 'templatesDir',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'worker_timeout': FieldMeta(
      yamlPath: 'worker_timeout',
      jsonKey: 'workerTimeout',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'memory.max_bytes': FieldMeta(
      yamlPath: 'memory.max_bytes',
      jsonKey: 'memory.maxBytes',
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
    'agent.effort': FieldMeta(
      yamlPath: 'agent.effort',
      jsonKey: 'agent.effort',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
      allowedValues: ['', 'low', 'medium', 'high', 'max'],
    ),
    'agent.max_turns': FieldMeta(
      yamlPath: 'agent.max_turns',
      jsonKey: 'agent.maxTurns',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      nullable: true,
      min: 1,
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
    'tasks.artifact_retention_days': FieldMeta(
      yamlPath: 'tasks.artifact_retention_days',
      jsonKey: 'tasks.artifactRetentionDays',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
      max: 3650,
    ),
    'tasks.completion_action': FieldMeta(
      yamlPath: 'tasks.completion_action',
      jsonKey: 'tasks.completionAction',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      allowedValues: ['review', 'accept'],
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
    'guard_audit.max_retention_days': FieldMeta(
      yamlPath: 'guard_audit.max_retention_days',
      jsonKey: 'guardAudit.maxRetentionDays',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
      max: 365,
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
    'logging.file': FieldMeta(
      yamlPath: 'logging.file',
      jsonKey: 'logging.file',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'logging.redact_patterns': FieldMeta(
      yamlPath: 'logging.redact_patterns',
      jsonKey: 'logging.redactPatterns',
      type: ConfigFieldType.stringList,
      mutability: ConfigMutability.restart,
      nullable: true,
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
    'context.exploration_summary_threshold': FieldMeta(
      yamlPath: 'context.exploration_summary_threshold',
      jsonKey: 'context.explorationSummaryThreshold',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1000,
    ),
    'context.compact_instructions': FieldMeta(
      yamlPath: 'context.compact_instructions',
      jsonKey: 'context.compactInstructions',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'context.warning_threshold': FieldMeta(
      yamlPath: 'context.warning_threshold',
      jsonKey: 'context.warningThreshold',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.live,
      min: 50,
      max: 99,
    ),

    // Search
    'search.backend': FieldMeta(
      yamlPath: 'search.backend',
      jsonKey: 'search.backend',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['fts5', 'qmd'],
    ),
    'search.qmd.host': FieldMeta(
      yamlPath: 'search.qmd.host',
      jsonKey: 'search.qmd.host',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'search.qmd.port': FieldMeta(
      yamlPath: 'search.qmd.port',
      jsonKey: 'search.qmd.port',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 65535,
    ),
    'search.default_depth': FieldMeta(
      yamlPath: 'search.default_depth',
      jsonKey: 'search.defaultDepth',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
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
    'channels.whatsapp.task_trigger.enabled': FieldMeta(
      yamlPath: 'channels.whatsapp.task_trigger.enabled',
      jsonKey: 'channels.whatsapp.taskTrigger.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.whatsapp.task_trigger.prefix': FieldMeta(
      yamlPath: 'channels.whatsapp.task_trigger.prefix',
      jsonKey: 'channels.whatsapp.taskTrigger.prefix',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.whatsapp.task_trigger.default_type': FieldMeta(
      yamlPath: 'channels.whatsapp.task_trigger.default_type',
      jsonKey: 'channels.whatsapp.taskTrigger.defaultType',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.whatsapp.task_trigger.auto_start': FieldMeta(
      yamlPath: 'channels.whatsapp.task_trigger.auto_start',
      jsonKey: 'channels.whatsapp.taskTrigger.autoStart',
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
    'channels.signal.task_trigger.enabled': FieldMeta(
      yamlPath: 'channels.signal.task_trigger.enabled',
      jsonKey: 'channels.signal.taskTrigger.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.signal.task_trigger.prefix': FieldMeta(
      yamlPath: 'channels.signal.task_trigger.prefix',
      jsonKey: 'channels.signal.taskTrigger.prefix',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.signal.task_trigger.default_type': FieldMeta(
      yamlPath: 'channels.signal.task_trigger.default_type',
      jsonKey: 'channels.signal.taskTrigger.defaultType',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.signal.task_trigger.auto_start': FieldMeta(
      yamlPath: 'channels.signal.task_trigger.auto_start',
      jsonKey: 'channels.signal.taskTrigger.autoStart',
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
    'channels.google_chat.oauth_credentials': FieldMeta(
      yamlPath: 'channels.google_chat.oauth_credentials',
      jsonKey: 'channels.googleChat.oauthCredentials',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
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
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['disabled', 'message', 'emoji', 'true', 'false'],
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
    'channels.google_chat.quote_reply': FieldMeta(
      yamlPath: 'channels.google_chat.quote_reply',
      jsonKey: 'channels.googleChat.quoteReplyMode',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['disabled', 'sender', 'native'],
    ),
    'channels.google_chat.reactions_auth': FieldMeta(
      yamlPath: 'channels.google_chat.reactions_auth',
      jsonKey: 'channels.googleChat.reactionsAuth',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['disabled', 'user'],
    ),
    'channels.google_chat.task_trigger.enabled': FieldMeta(
      yamlPath: 'channels.google_chat.task_trigger.enabled',
      jsonKey: 'channels.googleChat.taskTrigger.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.task_trigger.prefix': FieldMeta(
      yamlPath: 'channels.google_chat.task_trigger.prefix',
      jsonKey: 'channels.googleChat.taskTrigger.prefix',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.task_trigger.default_type': FieldMeta(
      yamlPath: 'channels.google_chat.task_trigger.default_type',
      jsonKey: 'channels.googleChat.taskTrigger.defaultType',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.task_trigger.auto_start': FieldMeta(
      yamlPath: 'channels.google_chat.task_trigger.auto_start',
      jsonKey: 'channels.googleChat.taskTrigger.autoStart',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),

    // Channels — Google Chat — Pub/Sub
    'channels.google_chat.pubsub.project_id': FieldMeta(
      yamlPath: 'channels.google_chat.pubsub.project_id',
      jsonKey: 'channels.googleChat.pubsub.projectId',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'channels.google_chat.pubsub.subscription': FieldMeta(
      yamlPath: 'channels.google_chat.pubsub.subscription',
      jsonKey: 'channels.googleChat.pubsub.subscription',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'channels.google_chat.pubsub.poll_interval_seconds': FieldMeta(
      yamlPath: 'channels.google_chat.pubsub.poll_interval_seconds',
      jsonKey: 'channels.googleChat.pubsub.pollIntervalSeconds',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 60,
    ),
    'channels.google_chat.pubsub.max_messages_per_pull': FieldMeta(
      yamlPath: 'channels.google_chat.pubsub.max_messages_per_pull',
      jsonKey: 'channels.googleChat.pubsub.maxMessagesPerPull',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 100,
    ),

    // Channels — Google Chat — Space Events
    'channels.google_chat.space_events.enabled': FieldMeta(
      yamlPath: 'channels.google_chat.space_events.enabled',
      jsonKey: 'channels.googleChat.spaceEvents.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.space_events.pubsub_topic': FieldMeta(
      yamlPath: 'channels.google_chat.space_events.pubsub_topic',
      jsonKey: 'channels.googleChat.spaceEvents.pubsubTopic',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'channels.google_chat.space_events.event_types': FieldMeta(
      yamlPath: 'channels.google_chat.space_events.event_types',
      jsonKey: 'channels.googleChat.spaceEvents.eventTypes',
      type: ConfigFieldType.stringList,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'channels.google_chat.space_events.include_resource': FieldMeta(
      yamlPath: 'channels.google_chat.space_events.include_resource',
      jsonKey: 'channels.googleChat.spaceEvents.includeResource',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.space_events.auth_mode': FieldMeta(
      yamlPath: 'channels.google_chat.space_events.auth_mode',
      jsonKey: 'channels.googleChat.spaceEvents.authMode',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['user', 'app'],
    ),
    'channels.google_chat.feedback.enabled': FieldMeta(
      yamlPath: 'channels.google_chat.feedback.enabled',
      jsonKey: 'channels.googleChat.feedback.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.feedback.min_feedback_delay': FieldMeta(
      yamlPath: 'channels.google_chat.feedback.min_feedback_delay',
      jsonKey: 'channels.googleChat.feedback.minFeedbackDelay',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.feedback.status_interval': FieldMeta(
      yamlPath: 'channels.google_chat.feedback.status_interval',
      jsonKey: 'channels.googleChat.feedback.statusInterval',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'channels.google_chat.feedback.status_style': FieldMeta(
      yamlPath: 'channels.google_chat.feedback.status_style',
      jsonKey: 'channels.googleChat.feedback.statusStyle',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['creative', 'minimal', 'silent'],
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

    // Governance
    'governance.admin_senders': FieldMeta(
      yamlPath: 'governance.admin_senders',
      jsonKey: 'governance.adminSenders',
      type: ConfigFieldType.stringList,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'governance.turn_progress.stall_timeout': FieldMeta(
      yamlPath: 'governance.turn_progress.stall_timeout',
      jsonKey: 'governance.turnProgress.stallTimeout',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'governance.turn_progress.stall_action': FieldMeta(
      yamlPath: 'governance.turn_progress.stall_action',
      jsonKey: 'governance.turnProgress.stallAction',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['warn', 'cancel', 'ignore'],
    ),
    'governance.queue_strategy': FieldMeta(
      yamlPath: 'governance.queue_strategy',
      jsonKey: 'governance.queueStrategy',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['fifo', 'fair'],
    ),
    'governance.crowd_coding.model': FieldMeta(
      yamlPath: 'governance.crowd_coding.model',
      jsonKey: 'governance.crowdCoding.model',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'governance.crowd_coding.effort': FieldMeta(
      yamlPath: 'governance.crowd_coding.effort',
      jsonKey: 'governance.crowdCoding.effort',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
      allowedValues: ['', 'low', 'medium', 'high', 'max'],
    ),
    'governance.rate_limits.per_sender.messages': FieldMeta(
      yamlPath: 'governance.rate_limits.per_sender.messages',
      jsonKey: 'governance.rateLimits.perSender.messages',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.rate_limits.per_sender.window': FieldMeta(
      yamlPath: 'governance.rate_limits.per_sender.window',
      jsonKey: 'governance.rateLimits.perSender.window',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 1440,
    ),
    'governance.rate_limits.per_sender.max_queued': FieldMeta(
      yamlPath: 'governance.rate_limits.per_sender.max_queued',
      jsonKey: 'governance.rateLimits.perSender.maxQueued',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.rate_limits.per_sender.max_pause_queued': FieldMeta(
      yamlPath: 'governance.rate_limits.per_sender.max_pause_queued',
      jsonKey: 'governance.rateLimits.perSender.maxPauseQueued',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.rate_limits.global.turns': FieldMeta(
      yamlPath: 'governance.rate_limits.global.turns',
      jsonKey: 'governance.rateLimits.global.turns',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.rate_limits.global.window': FieldMeta(
      yamlPath: 'governance.rate_limits.global.window',
      jsonKey: 'governance.rateLimits.global.window',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 1440,
    ),
    'governance.budget.daily_tokens': FieldMeta(
      yamlPath: 'governance.budget.daily_tokens',
      jsonKey: 'governance.budget.dailyTokens',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.budget.action': FieldMeta(
      yamlPath: 'governance.budget.action',
      jsonKey: 'governance.budget.action',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['warn', 'block'],
    ),
    'governance.budget.timezone': FieldMeta(
      yamlPath: 'governance.budget.timezone',
      jsonKey: 'governance.budget.timezone',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
    ),
    'governance.loop_detection.enabled': FieldMeta(
      yamlPath: 'governance.loop_detection.enabled',
      jsonKey: 'governance.loopDetection.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'governance.loop_detection.max_consecutive_turns': FieldMeta(
      yamlPath: 'governance.loop_detection.max_consecutive_turns',
      jsonKey: 'governance.loopDetection.maxConsecutiveTurns',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.loop_detection.max_tokens_per_minute': FieldMeta(
      yamlPath: 'governance.loop_detection.max_tokens_per_minute',
      jsonKey: 'governance.loopDetection.maxTokensPerMinute',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.loop_detection.velocity_window_minutes': FieldMeta(
      yamlPath: 'governance.loop_detection.velocity_window_minutes',
      jsonKey: 'governance.loopDetection.velocityWindowMinutes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'governance.loop_detection.max_consecutive_identical_tool_calls': FieldMeta(
      yamlPath: 'governance.loop_detection.max_consecutive_identical_tool_calls',
      jsonKey: 'governance.loopDetection.maxConsecutiveIdenticalToolCalls',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
    ),
    'governance.loop_detection.action': FieldMeta(
      yamlPath: 'governance.loop_detection.action',
      jsonKey: 'governance.loopDetection.action',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['abort', 'warn'],
    ),
    'canvas.enabled': FieldMeta(
      yamlPath: 'canvas.enabled',
      jsonKey: 'canvas.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'canvas.share.default_permission': FieldMeta(
      yamlPath: 'canvas.share.default_permission',
      jsonKey: 'canvas.share.defaultPermission',
      type: ConfigFieldType.enum_,
      mutability: ConfigMutability.restart,
      allowedValues: ['view', 'interact'],
    ),
    'canvas.share.default_ttl': FieldMeta(
      yamlPath: 'canvas.share.default_ttl',
      jsonKey: 'canvas.share.defaultTtlMinutes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'canvas.share.max_connections': FieldMeta(
      yamlPath: 'canvas.share.max_connections',
      jsonKey: 'canvas.share.maxConnections',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
    ),
    'canvas.share.auto_share': FieldMeta(
      yamlPath: 'canvas.share.auto_share',
      jsonKey: 'canvas.share.autoShare',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'canvas.share.show_qr': FieldMeta(
      yamlPath: 'canvas.share.show_qr',
      jsonKey: 'canvas.share.showQr',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'canvas.workshop_mode.task_board': FieldMeta(
      yamlPath: 'canvas.workshop_mode.task_board',
      jsonKey: 'canvas.workshopMode.taskBoard',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'canvas.workshop_mode.show_contributor_stats': FieldMeta(
      yamlPath: 'canvas.workshop_mode.show_contributor_stats',
      jsonKey: 'canvas.workshopMode.showContributorStats',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'canvas.workshop_mode.show_budget_bar': FieldMeta(
      yamlPath: 'canvas.workshop_mode.show_budget_bar',
      jsonKey: 'canvas.workshopMode.showBudgetBar',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'advisor.enabled': FieldMeta(
      yamlPath: 'advisor.enabled',
      jsonKey: 'advisor.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'advisor.model': FieldMeta(
      yamlPath: 'advisor.model',
      jsonKey: 'advisor.model',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'advisor.effort': FieldMeta(
      yamlPath: 'advisor.effort',
      jsonKey: 'advisor.effort',
      type: ConfigFieldType.string,
      mutability: ConfigMutability.restart,
      nullable: true,
      allowedValues: ['', 'low', 'medium', 'high', 'max'],
    ),
    'advisor.triggers': FieldMeta(
      yamlPath: 'advisor.triggers',
      jsonKey: 'advisor.triggers',
      type: ConfigFieldType.stringList,
      mutability: ConfigMutability.restart,
      nullable: true,
    ),
    'advisor.periodic_interval_minutes': FieldMeta(
      yamlPath: 'advisor.periodic_interval_minutes',
      jsonKey: 'advisor.periodicIntervalMinutes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 1440,
    ),
    'advisor.max_window_turns': FieldMeta(
      yamlPath: 'advisor.max_window_turns',
      jsonKey: 'advisor.maxWindowTurns',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 100,
    ),
    'advisor.max_prior_reflections': FieldMeta(
      yamlPath: 'advisor.max_prior_reflections',
      jsonKey: 'advisor.maxPriorReflections',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 0,
      max: 20,
    ),
    'features.thread_binding.enabled': FieldMeta(
      yamlPath: 'features.thread_binding.enabled',
      jsonKey: 'features.threadBinding.enabled',
      type: ConfigFieldType.bool_,
      mutability: ConfigMutability.restart,
    ),
    'features.thread_binding.idle_timeout_minutes': FieldMeta(
      yamlPath: 'features.thread_binding.idle_timeout_minutes',
      jsonKey: 'features.threadBinding.idleTimeoutMinutes',
      type: ConfigFieldType.int_,
      mutability: ConfigMutability.restart,
      min: 1,
      max: 1440,
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
