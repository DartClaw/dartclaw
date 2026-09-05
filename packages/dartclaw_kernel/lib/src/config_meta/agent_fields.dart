part of '../config_meta.dart';

/// Agent, harness, provider, session, task and memory fields.
const Map<String, FieldMeta> _agentFields = {
  'scheduling.heartbeat.enabled': FieldMeta(
    yamlPath: 'scheduling.heartbeat.enabled',
    jsonKey: 'scheduling.heartbeat.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.live,
    description: 'Run the periodic unattended turn. Off means nothing fires from the schedule.',
  ),
  'memory.max_bytes': FieldMeta(
    yamlPath: 'memory.max_bytes',
    jsonKey: 'memory.maxBytes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description:
        'Byte budget applied to each prompt memory projection – the index and the errors section – '
        'independently. Must be positive; a larger budget spends more of every prompt.',
    min: 1,
  ),
  'agent.model': FieldMeta(
    yamlPath: 'agent.model',
    jsonKey: 'agent.model',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Model for main chat, cron and heartbeat turns. Accepts provider/model shorthand; null leaves the choice to the harness.',
    nullable: true,
  ),
  'agent.provider': FieldMeta(
    yamlPath: 'agent.provider',
    jsonKey: 'agent.provider',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Harness driving the primary lane: claude, codex, or an ACP agent id. Must not be blank.',
  ),
  'agent.effort': FieldMeta(
    yamlPath: 'agent.effort',
    jsonKey: 'agent.effort',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Reasoning effort handed verbatim to the harness. Null leaves its own default.',
    nullable: true,
  ),
  'agent.max_turns': FieldMeta(
    yamlPath: 'agent.max_turns',
    jsonKey: 'agent.maxTurns',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Ceiling on assistant turns inside one exchange. Null leaves the harness default.',
    nullable: true,
    min: 1,
  ),
  'agent.execution': FieldMeta(
    yamlPath: 'agent.execution',
    jsonKey: 'agent.execution',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'Where primary-lane turns run. Selecting container demands container isolation be on — host is never substituted silently.',
    nullable: true,
    allowedValues: ['host', 'container'],
  ),
  'tasks.artifact_retention_days': FieldMeta(
    yamlPath: 'tasks.artifact_retention_days',
    jsonKey: 'tasks.artifactRetentionDays',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Days a finished task keeps its artifacts before maintenance deletes them. 0 keeps them indefinitely.',
    min: 0,
    max: 3650,
  ),
  'tasks.completion_action': FieldMeta(
    yamlPath: 'tasks.completion_action',
    jsonKey: 'tasks.completionAction',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'What a finished task does next: review parks it for a human, accept lands it without one.',
    allowedValues: ['review', 'accept'],
  ),
  'tasks.budget.default_max_tokens': FieldMeta(
    yamlPath: 'tasks.budget.default_max_tokens',
    jsonKey: 'tasks.budget.defaultMaxTokens',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description:
        'Token ceiling applied to a task that names none. Any value at or below zero means unbudgeted, which is also '
        'the default.',
  ),
  'tasks.budget.warning_threshold': FieldMeta(
    yamlPath: 'tasks.budget.warning_threshold',
    jsonKey: 'tasks.budget.warningThreshold',
    type: ConfigFieldType.double_,
    mutability: ConfigMutability.restart,
    description:
        'Fraction of a task token budget at which it warns once, between 0 and 1. Defaults to 0.8; the task still '
        'fails at the full budget regardless.',
    min: 0,
    max: 1,
  ),
  'tasks.execution': FieldMeta(
    yamlPath: 'tasks.execution',
    jsonKey: 'tasks.execution',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.readonly,
    description:
        'Execution mode for background tasks. container demands container isolation be on; task security profiles '
        'are declared separately through the authenticated task API.',
    allowedValues: ['host', 'container'],
  ),
  'tasks.worktree.base_ref': FieldMeta(
    yamlPath: 'tasks.worktree.base_ref',
    jsonKey: 'tasks.worktree.baseRef',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Git ref a task worktree branches from.',
  ),
  'tasks.worktree.stale_timeout_hours': FieldMeta(
    yamlPath: 'tasks.worktree.stale_timeout_hours',
    jsonKey: 'tasks.worktree.staleTimeoutHours',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Hours an idle task worktree survives before cleanup removes it.',
    min: 1,
    max: 168,
  ),
  'tasks.worktree.merge_strategy': FieldMeta(
    yamlPath: 'tasks.worktree.merge_strategy',
    jsonKey: 'tasks.worktree.mergeStrategy',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'How an accepted task lands: squash collapses its commits into one, merge keeps them.',
    allowedValues: ['squash', 'merge'],
  ),
  'sessions.reset_hour': FieldMeta(
    yamlPath: 'sessions.reset_hour',
    jsonKey: 'sessions.resetHour',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.reloadable,
    description: 'Local hour at which main, channel and cron sessions are archived and restarted under the same key. -1 keeps them until idle timeout or maintenance. User-created sessions are never reset.',
    min: -1,
    max: 23,
  ),
  'sessions.idle_timeout_minutes': FieldMeta(
    yamlPath: 'sessions.idle_timeout_minutes',
    jsonKey: 'sessions.idleTimeoutMinutes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.reloadable,
    description: 'Minutes of silence before an eligible session resets. 0 turns the timeout off.',
    min: 0,
  ),
  'sessions.dm_scope': FieldMeta(
    yamlPath: 'sessions.dm_scope',
    jsonKey: 'sessions.dmScope',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.live,
    description: 'How direct messages map onto sessions: one shared, one per contact, or one per contact per channel.',
    allowedValues: ['shared', 'per-contact', 'per-channel-contact'],
  ),
  'sessions.group_scope': FieldMeta(
    yamlPath: 'sessions.group_scope',
    jsonKey: 'sessions.groupScope',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.live,
    description: 'How group messages map onto sessions: one shared per group, or one per member.',
    allowedValues: ['shared', 'per-member'],
  ),
  'sessions.maintenance.mode': FieldMeta(
    yamlPath: 'sessions.maintenance.mode',
    jsonKey: 'sessions.maintenance.mode',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'warn reports what maintenance would remove; enforce removes it.',
    allowedValues: ['warn', 'enforce'],
  ),
  'sessions.maintenance.prune_after_days': FieldMeta(
    yamlPath: 'sessions.maintenance.prune_after_days',
    jsonKey: 'sessions.maintenance.pruneAfterDays',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Days of inactivity after which a session is archived. 0 archives nothing.',
    min: 0,
  ),
  'sessions.maintenance.max_sessions': FieldMeta(
    yamlPath: 'sessions.maintenance.max_sessions',
    jsonKey: 'sessions.maintenance.maxSessions',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Cap on retained sessions, oldest pruned first. 0 means uncapped.',
    min: 0,
  ),
  'sessions.maintenance.max_disk_mb': FieldMeta(
    yamlPath: 'sessions.maintenance.max_disk_mb',
    jsonKey: 'sessions.maintenance.maxDiskMb',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Disk budget in megabytes for stored sessions. 0 means unbudgeted.',
    min: 0,
  ),
  'sessions.maintenance.cron_retention_hours': FieldMeta(
    yamlPath: 'sessions.maintenance.cron_retention_hours',
    jsonKey: 'sessions.maintenance.cronRetentionHours',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Hours an orphaned cron session survives before deletion. 0 deletes none.',
    min: 0,
  ),
  'sessions.maintenance.schedule': FieldMeta(
    yamlPath: 'sessions.maintenance.schedule',
    jsonKey: 'sessions.maintenance.schedule',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Cron expression driving the automatic maintenance run. An empty string disables it.',
  ),
  'scheduling.heartbeat.interval_minutes': FieldMeta(
    yamlPath: 'scheduling.heartbeat.interval_minutes',
    jsonKey: 'scheduling.heartbeat.intervalMinutes',
    type: ConfigFieldType.int_,
    // The heartbeat is a ScheduledJob, whose interval is fixed at registration:
    // ScheduleService exposes pause/resume, not job-definition mutation.
    mutability: ConfigMutability.restart,
    description: 'Minutes between heartbeat turns. Each one costs a full turn of tokens.',
    min: 1,
    max: 1440,
  ),
  'context.reserve_tokens': FieldMeta(
    yamlPath: 'context.reserve_tokens',
    jsonKey: 'context.reserveTokens',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.reloadable,
    description: 'Tokens held back from the window so a compaction flush always fits.',
    min: 1,
  ),
  'context.max_result_bytes': FieldMeta(
    yamlPath: 'context.max_result_bytes',
    jsonKey: 'context.maxResultBytes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.reloadable,
    description: 'Outer cap in bytes on every successful tool result the MCP endpoint returns. An oversized one arrives as head and tail around a truncation marker.',
    min: 1,
  ),
  'context.compact_instructions': FieldMeta(
    yamlPath: 'context.compact_instructions',
    jsonKey: 'context.compactInstructions',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Extra guidance handed to the model when it compacts a conversation. Null uses the built-in wording.',
    nullable: true,
  ),
  'context.warning_threshold': FieldMeta(
    yamlPath: 'context.warning_threshold',
    jsonKey: 'context.warningThreshold',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.live,
    description: 'Percentage of the window at which the UI warns about remaining room. Clamped to 50–99.',
    min: 50,
    max: 99,
  ),
  'context.identifier_preservation': FieldMeta(
    yamlPath: 'context.identifier_preservation',
    jsonKey: 'context.identifierPreservation',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'How hard compaction works to keep literal identifiers: strict, off, or custom wording.',
    allowedValues: ['strict', 'off', 'custom'],
  ),
  'context.identifier_instructions': FieldMeta(
    yamlPath: 'context.identifier_instructions',
    jsonKey: 'context.identifierInstructions',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'The custom wording used when identifier preservation is set to custom.',
    nullable: true,
  ),
  'mcp_servers': FieldMeta(
    yamlPath: 'mcp_servers',
    jsonKey: 'mcpServers',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.restart,
    description: 'External MCP servers keyed by the name their tools are surfaced under. Each entry declares exactly one transport.',
    entry: ObjectEntry(
      fields: {
        'command': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Executable launched for a stdio server. Exactly one of it and url must be present.',
          nullable: true,
        ),
        'url': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Absolute endpoint of an HTTP server. Plain http is accepted only for a literal loopback host.',
          nullable: true,
        ),
        'network_class': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'How far the server can reach, which decides what egress mediation applies. Required.',
          allowedValues: ['local', 'private', 'public'],
        ),
        'enabled': EntryFieldMeta(
          type: ConfigFieldType.bool_,
          description: 'Whether the server is used. It is forced off at load when its credential does not resolve.',
        ),
        'credential': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Names a credentials entry presented to this server. Without one the server is disabled — never inline a secret here.',
          nullable: true,
        ),
        'allow_tools': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Tools this server may actually run. Empty denies every outbound call.',
        ),
        'surface_tools': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Tools listed to the harness. Empty exposes none, so the model never sees them.',
        ),
        'rate_limit.calls': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Calls permitted inside the window. 0 leaves the server unthrottled.',
          min: 0,
        ),
        'rate_limit.window_seconds': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Length of the call window in seconds. Defaults to 60.',
          min: 0,
        ),
        'token_budget.tokens': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Tokens this server results may consume inside the window. 0 leaves it unbudgeted.',
          min: 0,
        ),
        'token_budget.window_seconds': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Length of the token window in seconds. Defaults to 60.',
          min: 0,
        ),
      },
    ),
  ),
  'memory.pruning.enabled': FieldMeta(
    yamlPath: 'memory.pruning.enabled',
    jsonKey: 'memory.pruning.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Archive and de-duplicate recognized memory entries on a schedule. Unrecognized content is preserved either way.',
  ),
  'memory.pruning.archive_after_days': FieldMeta(
    yamlPath: 'memory.pruning.archive_after_days',
    jsonKey: 'memory.pruning.archiveAfterDays',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Days before a canonical memory entry is archived. Must be positive.',
    min: 1,
  ),
  'memory.pruning.schedule': FieldMeta(
    yamlPath: 'memory.pruning.schedule',
    jsonKey: 'memory.pruning.schedule',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Cron expression driving the archival run.',
  ),
  'memory.journal.enabled': FieldMeta(
    yamlPath: 'memory.journal.enabled',
    jsonKey: 'memory.journal.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Distil each day of turn logs into canonical observations. Opt-in, and it costs one turn per run.',
  ),
  'memory.journal.schedule': FieldMeta(
    yamlPath: 'memory.journal.schedule',
    jsonKey: 'memory.journal.schedule',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Cron expression driving the distillation run.',
  ),
  'memory.curation.enabled': FieldMeta(
    yamlPath: 'memory.curation.enabled',
    jsonKey: 'memory.curation.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description:
        'Revise, merge and remove canonical memory entries on a schedule. Opt-in, and it costs one turn per run.',
  ),
  'memory.curation.schedule': FieldMeta(
    yamlPath: 'memory.curation.schedule',
    jsonKey: 'memory.curation.schedule',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Cron expression driving the curation run.',
  ),
  'knowledge.inbox.enabled': FieldMeta(
    yamlPath: 'knowledge.inbox.enabled',
    jsonKey: 'knowledge.inbox.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Watch the filesystem inbox and ingest what is dropped there. Off by default; every file costs one extraction turn.',
  ),
  'knowledge.inbox.interval_minutes': FieldMeta(
    yamlPath: 'knowledge.inbox.interval_minutes',
    jsonKey: 'knowledge.inbox.intervalMinutes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Minutes between sweeps of the drop directory. Clamped to 1–1440.',
    min: 1,
    max: 1440,
  ),
  'knowledge.inbox.max_bytes': FieldMeta(
    yamlPath: 'knowledge.inbox.max_bytes',
    jsonKey: 'knowledge.inbox.maxBytes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Largest source file that will be read, in bytes. Anything above it is skipped.',
    min: 1,
    max: 52428800,
  ),
  'knowledge.inbox.retry_attempts': FieldMeta(
    yamlPath: 'knowledge.inbox.retry_attempts',
    jsonKey: 'knowledge.inbox.retryAttempts',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'How often the nondeterministic extraction turn is retried before the source is quarantined.',
    min: 0,
    max: 10,
  ),
  'knowledge.inbox.processed_retention_days': FieldMeta(
    yamlPath: 'knowledge.inbox.processed_retention_days',
    jsonKey: 'knowledge.inbox.processedRetentionDays',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Days an already-ingested source is kept before deletion. 0 keeps it indefinitely.',
    min: 0,
    max: 3650,
  ),
  'knowledge.inbox.delivery_mode': FieldMeta(
    yamlPath: 'knowledge.inbox.delivery_mode',
    jsonKey: 'knowledge.inbox.deliveryMode',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Where the run report goes: nowhere, announced in chat, or posted to a webhook.',
    allowedValues: ['none', 'announce', 'webhook'],
  ),
  'knowledge.inbox.effort': FieldMeta(
    yamlPath: 'knowledge.inbox.effort',
    jsonKey: 'knowledge.inbox.effort',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Reasoning effort of the extraction turn. Billed per file — lower it for raw material you genuinely want compressed.',
  ),
  'knowledge.wiki_lint.enabled': FieldMeta(
    yamlPath: 'knowledge.wiki_lint.enabled',
    jsonKey: 'knowledge.wikiLint.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Run the wiki lint report on a schedule. It reports only and never rewrites a page.',
  ),
  'knowledge.wiki_lint.interval_minutes': FieldMeta(
    yamlPath: 'knowledge.wiki_lint.interval_minutes',
    jsonKey: 'knowledge.wikiLint.intervalMinutes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Minutes between lint runs. Clamped to 1–1440.',
    min: 1,
    max: 1440,
  ),
  'knowledge.wiki_lint.delivery_mode': FieldMeta(
    yamlPath: 'knowledge.wiki_lint.delivery_mode',
    jsonKey: 'knowledge.wikiLint.deliveryMode',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Where the lint report goes: nowhere, announced in chat, or posted to a webhook.',
    allowedValues: ['none', 'announce', 'webhook'],
  ),
  // --- Agent — tool policy, history and logical agents ---
  'agent.disallowed_tools': FieldMeta(
    yamlPath: 'agent.disallowed_tools',
    jsonKey: 'agent.disallowedTools',
    type: ConfigFieldType.stringList,
    mutability: ConfigMutability.restart,
    description: 'Tool names withheld from primary-lane turns. Empty withholds nothing beyond the harness defaults.',
  ),
  'agent.history.max_message_chars': FieldMeta(
    yamlPath: 'agent.history.max_message_chars',
    jsonKey: 'agent.history.maxMessageChars',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Characters of one replayed message kept when history is rebuilt. Values under 500 are refused.',
    min: 500,
  ),
  'agent.history.max_total_chars': FieldMeta(
    yamlPath: 'agent.history.max_total_chars',
    jsonKey: 'agent.history.maxTotalChars',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description:
        'Characters of replayed history in total. Values under 5000, or below the per-message cap, are refused.',
    min: 5000,
  ),
  'agent.agents': FieldMeta(
    yamlPath: 'agent.agents',
    jsonKey: 'agent.agents',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.restart,
    description: 'Logical agents keyed by the id the session tools address them with. The built-in search agent is defined here too.',
    entry: ObjectEntry(
      fields: {
        'description': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'One line shown in the spawn tool schema so a caller knows when to pick this agent.',
        ),
        'prompt': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'System prompt used for this agent turns. Empty leaves the agent unguided.',
        ),
        'provider': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Harness driving this agent. Null inherits the primary lane setting; blank is refused.',
          nullable: true,
        ),
        'security_profile': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Container posture: workspace can write the checkout, restricted cannot. It never selects host or container placement.',
          nullable: true,
          allowedValues: ['workspace', 'restricted'],
        ),
        'execution': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Where this agent runs. Null inherits the primary lane; host contradicts a configured container profile and is refused.',
          nullable: true,
          allowedValues: ['host', 'container'],
        ),
        'tools': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Tools this agent may call. Empty enforces no allowlist at all, which is warned about at load.',
        ),
        'denied_tools': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Tools blocked for this agent even when the allowlist would admit them.',
        ),
        'max_response_bytes': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Ceiling on what this agent returns to its caller, in bytes. Defaults to 5 MiB.',
          min: 1,
        ),
        'model': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Model override for this agent. Null inherits the primary lane setting.',
          nullable: true,
        ),
        'effort': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Reasoning-effort override for this agent. Null inherits the primary lane setting.',
          nullable: true,
        ),
        'output_schema': EntryFieldMeta(
          type: ConfigFieldType.objectMap,
          description: 'Inline JSON Schema the agent answer must conform to: a closed subset of type, properties, required, items, enum and additionalProperties, with every object level forced closed. A non-conforming answer fails the turn instead of being repaired or truncated; an unsupported keyword is refused at load.',
          entry: OpaqueEntry(
            reason: 'The value is a JSON Schema document, keyed by schema keyword rather than by a declared field; parseOutputSchema is its one validating authority.',
          ),
        ),
      },
    ),
  ),

  // --- Harness — ACP agent registrations ---
  'harness.acp.agents': FieldMeta(
    yamlPath: 'harness.acp.agents',
    jsonKey: 'harness.acp.agents',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.restart,
    description: 'ACP provider identities keyed by id. Each registration defines a spawn and its security classification; ACP runs on the host only.',
    entry: ObjectEntry(
      fields: {
        'binary': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Executable spawned for this ACP client. Required — a registration without it is skipped.',
        ),
        'args': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Arguments passed to the executable, e.g. the ACP subcommand and its builtins.',
        ),
        'topology': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'How the client reaches its model. Omitted means unverified, which claims no guard mediation.',
          nullable: true,
          allowedValues: ['direct', 'relay', 'unverified'],
        ),
        'model_provider': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Vendor whose model the client talks to. It selects validation and routing, never a credential.',
          nullable: true,
        ),
        'verification': EntryFieldMeta(
          type: ConfigFieldType.string,
          description:
              'Evidence backing a guard-mediation claim, e.g. startup_probe. Required once mediation is claimed.',
          nullable: true,
        ),
        'requires_guard_mediation': EntryFieldMeta(
          type: ConfigFieldType.bool_,
          description: 'Operator declaration that the guard chain sees this client tool calls. It demands a direct topology plus evidence.',
        ),
        'required_builtins': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Builtins the client must load, e.g. developer for a guarded Goose registration.',
        ),
        'container_isolation_required': EntryFieldMeta(
          type: ConfigFieldType.bool_,
          description:
              'Demands a container, which ACP has no runnable execution for — a true here is refused at startup.',
        ),
        'container_profile': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Container posture the execution policy would resolve to. Leaving it set on a container-enabled deployment pins the agent to a refused policy.',
          nullable: true,
          allowedValues: ['restricted', 'workspace'],
        ),
        'credential': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Names a credentials entry whose API key is injected under the environment variable it declares. The only credential an ACP spawn ever carries.',
          nullable: true,
        ),
      },
    ),
  ),

  // --- Providers and credentials ---
  'providers': FieldMeta(
    yamlPath: 'providers',
    jsonKey: 'providers',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.restart,
    description: 'Harness providers keyed by id. Keys beyond the ones declared here are forwarded verbatim as provider-specific options.',
    entry: ObjectEntry(
      fields: {
        'executable': EntryFieldMeta(
          type: ConfigFieldType.string,
          description:
              'Binary name or path launched for this provider. Required — an entry without it is skipped at load.',
        ),
        'pool_size': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Hard ceiling on concurrent worker leases for this provider. 0 means the default of one.',
          min: 0,
        ),
        'auth': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Which credential is presented. Unset lets an alias inherit its family choice; a forced value never falls back to the other kind.',
          nullable: true,
          allowedValues: ['auto', 'subscription', 'api_key'],
        ),
        'inherit_user_settings': EntryFieldMeta(
          type: ConfigFieldType.bool_,
          description: 'Claude only. True loads user, project and local settings; false passes project-only sources.',
        ),
        'approval': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Prompt-gating axis. Only never opts a trusted run into full access.',
          nullable: true,
          allowedValues: ['on-request', 'unless-allow-listed', 'never'],
        ),
        'sandbox': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'OS-isolation axis: read-only, workspace-write or danger-full-access. A map value is forwarded verbatim as a raw native settings block.',
          nullable: true,
        ),
      },
    ),
  ),
  'credentials': FieldMeta(
    yamlPath: 'credentials',
    jsonKey: 'credentials',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.readonly,
    description: 'API-key and GitHub-token entries keyed by the name other sections reference. Read-only: secret material is never editable through the API, and subscription credentials never live here.',
    entry: ObjectEntry(
      fields: {
        'type': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Which kind of secret the entry holds. Omitted means an API key.',
          nullable: true,
          allowedValues: ['api-key', 'apiKey', 'github-token', 'githubToken'],
        ),
        'api_key': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'The key itself, normally an environment reference so the literal stays out of the file.',
          nullable: true,
        ),
        'token': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'The GitHub token, normally an environment reference so the literal stays out of the file.',
          nullable: true,
        ),
        'repository': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Optional owner/name scope guard limiting where a GitHub token may be used.',
          nullable: true,
        ),
      },
    ),
  ),

  // --- Projects ---
  'projects.fetchCooldownMinutes': FieldMeta(
    yamlPath: 'projects.fetchCooldownMinutes',
    jsonKey: 'projects.fetchCooldownMinutes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Minutes a freshness check skips the git fetch after a successful one. Default 5.',
    min: 0,
  ),
  'projects.allowApiLocalPath': FieldMeta(
    yamlPath: 'projects.allowApiLocalPath',
    jsonKey: 'projects.allowApiLocalPath',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.readonly,
    description:
        'Let the API register projects pointing at existing host directories. Downgraded to false unless an allowlist '
        'bounds it. Read-only: it decides whether the API may reach the host filesystem, so it must not itself be '
        'settable through the API.',
  ),
  'projects.localPathAllowlist': FieldMeta(
    yamlPath: 'projects.localPathAllowlist',
    jsonKey: 'projects.localPathAllowlist',
    type: ConfigFieldType.stringList,
    mutability: ConfigMutability.readonly,
    description:
        'Absolute directories a local-path project may live under. Empty bounds nothing, which is why it gates the '
        'API flag. Read-only for the same reason: widening it through the API would lift its own bound.',
  ),
  'projects': FieldMeta(
    yamlPath: 'projects',
    jsonKey: 'projects',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.restart,
    description:
        'Absolute directories a local-path project may live under. Empty bounds nothing, which is why it gates the API '
        'flag. Read-only for the same reason: widening it through the API would lift its own bound.',
    entry: ObjectEntry(
      fields: {
        'remote': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Git URL cloned for this project. Exactly one of it and localPath must be supplied.',
          nullable: true,
        ),
        'localPath': EntryFieldMeta(
          type: ConfigFieldType.string,
          description:
              'Existing checkout used directly. Must be absolute, free of traversal, and inside the allowlist.',
          nullable: true,
        ),
        'branch': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Ref tracked and branched from. Defaults to main for a remote, and to the current checkout branch for a local path.',
        ),
        'credentials': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Names a github-token credentials entry used for pushes and pull requests.',
          nullable: true,
        ),
        'default': EntryFieldMeta(
          type: ConfigFieldType.bool_,
          description: 'Pick this project when a new task names none.',
        ),
        'clone.strategy': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'How much history is fetched. shallow is cheapest; full is needed for history-dependent work.',
          allowedValues: ['shallow', 'full', 'sparse'],
        ),
        'pr.strategy': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'What a finished task produces: a pushed branch only, or a GitHub pull request.',
          allowedValues: ['branch-only', 'github-pr'],
        ),
        'pr.draft': EntryFieldMeta(
          type: ConfigFieldType.bool_,
          description: 'Open the pull request as a draft so review is opt-in.',
        ),
        'pr.labels': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Labels applied to every pull request this project opens.',
        ),
      },
    ),
  ),

  // --- Sessions — model overrides and per-channel scoping ---
  'sessions.model': FieldMeta(
    yamlPath: 'sessions.model',
    jsonKey: 'sessions.model',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Model used for scoped conversational turns. Null inherits the primary lane setting.',
    nullable: true,
  ),
  'sessions.effort': FieldMeta(
    yamlPath: 'sessions.effort',
    jsonKey: 'sessions.effort',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Reasoning effort for scoped conversational turns. Null inherits the primary lane setting.',
    nullable: true,
  ),
  'sessions.channels': FieldMeta(
    yamlPath: 'sessions.channels',
    jsonKey: 'sessions.channels',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.restart,
    description:
        'Per-channel overrides keyed by channel name. An entry that sets nothing is dropped rather than stored empty.',
    entry: ObjectEntry(
      fields: {
        'dm_scope': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Overrides how this channel one-to-one messages map onto sessions.',
          nullable: true,
          allowedValues: ['shared', 'per-contact', 'per-channel-contact'],
        ),
        'group_scope': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Overrides how this channel group messages map onto sessions.',
          nullable: true,
          allowedValues: ['shared', 'per-member'],
        ),
        'model': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Model override for turns arriving on this channel.',
          nullable: true,
        ),
        'effort': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Reasoning-effort override for turns arriving on this channel.',
          nullable: true,
        ),
      },
    ),
  ),

  // --- Scheduling ---
  'scheduling.jobs': FieldMeta(
    yamlPath: 'scheduling.jobs',
    jsonKey: 'scheduling.jobs',
    type: ConfigFieldType.objectList,
    mutability: ConfigMutability.restart,
    description: 'Unattended jobs, each firing a prompt turn or creating a task. Their prompt bodies are never validated here — an empty one only fails when the job runs.',
    entry: ObjectEntry(
      fields: {
        'id': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Stable identifier for this job. Required; name is accepted as a compatibility alias.',
        ),
        'name': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Compatibility alias for id. Prefer id in new configs.',
          nullable: true,
        ),
        'type': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description:
              'What firing does: run a prompt turn, or create a task from the block below. Defaults to prompt.',
          allowedValues: ['prompt', 'task'],
        ),
        'prompt': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Text handed to the agent when a prompt job fires. Required for that kind, and passed through unvalidated.',
          nullable: true,
        ),
        // Union: a bare cron string, or a map. Both arms are declared, because
        // ConfigFieldType has no union member and a consumer deriving a schema
        // from the string arm alone would reject the map form.
        'schedule': EntryFieldMeta(
          type: ConfigFieldType.string,
          description:
              'Shorthand form: a bare five-field cron expression, equivalent to a cron map with that expression.',
        ),
        'schedule.type': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Map form: which schedule kind the entry carries. Omitted inside a map means cron.',
          allowedValues: ['cron', 'interval', 'once'],
        ),
        'schedule.expression': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Five-field cron expression. Required for a cron schedule, and a job without one is refused.',
          nullable: true,
        ),
        'schedule.minutes': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Minutes between firings for an interval schedule. Must be at least 1, or the job is refused.',
          nullable: true,
          min: 1,
        ),
        'schedule.at': EntryFieldMeta(
          type: ConfigFieldType.string,
          description:
              'ISO-8601 instant a once schedule fires at. Required for that kind, and an unparseable value is refused.',
          nullable: true,
        ),
        'enabled': EntryFieldMeta(
          type: ConfigFieldType.bool_,
          description: 'Whether the job is active. Defaults to true.',
        ),
        'delivery': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'Where the result goes: nowhere, announced in chat, or posted to a webhook.',
          allowedValues: ['none', 'announce', 'webhook'],
        ),
        'webhook_url': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Endpoint the result is posted to when delivery is by webhook.',
          nullable: true,
        ),
        'retry.attempts': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'How often a failed firing is retried. Defaults to 0, meaning no retry.',
          min: 0,
        ),
        'retry.delay_seconds': EntryFieldMeta(
          type: ConfigFieldType.int_,
          description: 'Seconds waited between retries. Defaults to 60.',
          min: 0,
        ),
        'model': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Model override for this job turn. Null inherits the primary lane setting.',
          nullable: true,
        ),
        'effort': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Reasoning-effort override for this job turn. Null inherits the primary lane setting.',
          nullable: true,
        ),
        'task': EntryFieldMeta(
          type: ConfigFieldType.objectMap,
          description: 'Template the created task is built from. Required when the kind is task.',
          nullable: true,
          entry: _scheduledTaskEntry,
        ),
      },
    ),
  ),
};

/// Shape of one `task:` block carried by a `scheduling.jobs` entry of type
/// `task`.
const ObjectEntry _scheduledTaskEntry = ObjectEntry(
  fields: {
    'title': EntryFieldMeta(type: ConfigFieldType.string, description: 'Title given to the created task. Required.'),
    'description': EntryFieldMeta(
      type: ConfigFieldType.string,
      description: 'Body handed to the agent as the task brief. Required.',
    ),
    'type': EntryFieldMeta(
      type: ConfigFieldType.string,
      description: 'Retired compatibility field. Optional and ignored; research and coding are refused.',
      nullable: true,
    ),
    'task_type': EntryFieldMeta(
      type: ConfigFieldType.string,
      description: 'Retired compatibility alias. Optional and ignored; research and coding are refused.',
      nullable: true,
    ),
    'acceptance_criteria': EntryFieldMeta(
      type: ConfigFieldType.string,
      description: 'What the created task must satisfy before it is considered finished.',
      nullable: true,
    ),
    'auto_start': EntryFieldMeta(
      type: ConfigFieldType.bool_,
      description: 'Queue the created task at once instead of leaving it a draft. Defaults to true.',
    ),
    'model': EntryFieldMeta(
      type: ConfigFieldType.string,
      description: 'Model override for the created task. Null inherits the primary lane setting.',
      nullable: true,
    ),
    'effort': EntryFieldMeta(
      type: ConfigFieldType.string,
      description: 'Reasoning-effort override for the created task. Null inherits the primary lane setting.',
      nullable: true,
    ),
    'token_budget': EntryFieldMeta(
      type: ConfigFieldType.int_,
      description: 'Token ceiling for the created task. Null leaves it unbudgeted.',
      nullable: true,
    ),
  },
);
