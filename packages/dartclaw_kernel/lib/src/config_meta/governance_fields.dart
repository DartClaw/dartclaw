part of '../config_meta.dart';

/// Governance, guard, alert and extension fields.
const Map<String, FieldMeta> _governanceFields = {
  'github.enabled': FieldMeta(
    yamlPath: 'github.enabled',
    jsonKey: 'github.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Accept inbound webhook deliveries and map them onto workflow runs.',
  ),
  'github.webhook_secret': FieldMeta(
    yamlPath: 'github.webhook_secret',
    jsonKey: 'github.webhookSecret',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description:
        'HMAC-SHA256 key deliveries are signed with. Required once the handler is on; an unsigned delivery is refused.',
    nullable: true,
  ),
  'github.webhook_path': FieldMeta(
    yamlPath: 'github.webhook_path',
    jsonKey: 'github.webhookPath',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'HTTP path the webhook endpoint is mounted at.',
  ),
  'github.triggers': FieldMeta(
    yamlPath: 'github.triggers',
    jsonKey: 'github.triggers',
    type: ConfigFieldType.objectList,
    mutability: ConfigMutability.restart,
    description: 'Rules mapping an inbound event onto the workflow that should launch.',
    entry: ObjectEntry(
      fields: {
        'event': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Webhook event the rule matches. Only pull_request is processed today; omitted defaults to it.',
        ),
        'actions': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Event actions that launch the workflow, e.g. opened and synchronize. Omitted uses those two.',
        ),
        'labels': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Labels the pull request must carry. Empty applies no label filter.',
        ),
        'workflow': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Name of the workflow definition launched on a match. Omitted defaults to code-review.',
        ),
      },
    ),
  ),
  'guard_audit.max_retention_days': FieldMeta(
    yamlPath: 'guard_audit.max_retention_days',
    jsonKey: 'guardAudit.maxRetentionDays',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Days of dated audit partitions kept before deletion. 0 keeps them indefinitely.',
    min: 0,
    max: 365,
  ),
  'guards.content.enabled': FieldMeta(
    yamlPath: 'guards.content.enabled',
    jsonKey: 'guards.content.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Classify model-visible content before it reaches the agent.',
  ),
  'guards.content.classifier': FieldMeta(
    yamlPath: 'guards.content.classifier',
    jsonKey: 'guards.content.classifier',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'Which classifier runs: the local Claude binary, or the Anthropic API.',
    allowedValues: ['claude_binary', 'anthropic_api'],
  ),
  'guards.content.model': FieldMeta(
    yamlPath: 'guards.content.model',
    jsonKey: 'guards.content.model',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Model the classifier uses. A cheaper one lowers the cost of every scan.',
  ),
  'guards.content.fail_open': FieldMeta(
    yamlPath: 'guards.content.fail_open',
    jsonKey: 'guards.content.failOpen',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Let unscorable content through when the classifier itself fails. Turning it on means unchecked material can reach the agent.',
  ),
  'guards.content.max_bytes': FieldMeta(
    yamlPath: 'guards.content.max_bytes',
    jsonKey: 'guards.content.maxBytes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Bytes handed to the classifier; longer material is truncated before scoring.',
    min: 1,
  ),
  'governance.admin_senders': FieldMeta(
    yamlPath: 'governance.admin_senders',
    jsonKey: 'governance.adminSenders',
    type: ConfigFieldType.stringList,
    mutability: ConfigMutability.restart,
    description: 'Sender IDs exempt from rate limits and budget blocks.',
    nullable: true,
  ),
  'governance.turn_limits.stall_timeout': FieldMeta(
    yamlPath: 'governance.turn_limits.stall_timeout',
    jsonKey: 'governance.turnLimits.stallTimeout',
    type: ConfigFieldType.string,
    alsoAccepts: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Duration such as 300s without provider progress before the stall action fires; zero disables it.',
    min: 0,
  ),
  'governance.turn_limits.stall_action': FieldMeta(
    yamlPath: 'governance.turn_limits.stall_action',
    jsonKey: 'governance.turnLimits.stallAction',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'What a stalled turn triggers: a warning, a cancellation, or nothing.',
    allowedValues: ['warn', 'cancel', 'ignore'],
  ),
  'governance.turn_limits.turn_timeout': FieldMeta(
    yamlPath: 'governance.turn_limits.turn_timeout',
    jsonKey: 'governance.turnLimits.turnTimeout',
    type: ConfigFieldType.string,
    alsoAccepts: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Wall-clock ceiling such as 1800s for a provider turn; zero disables it.',
    min: 0,
  ),
  'governance.queue_strategy': FieldMeta(
    yamlPath: 'governance.queue_strategy',
    jsonKey: 'governance.queueStrategy',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'How waiting turns are picked: fifo by arrival, or fair round-robin across senders.',
    allowedValues: ['fifo', 'fair'],
  ),
  'governance.crowd_coding.model': FieldMeta(
    yamlPath: 'governance.crowd_coding.model',
    jsonKey: 'governance.crowdCoding.model',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Model used for crowd-coding turns. Null inherits the primary lane setting.',
    nullable: true,
  ),
  'governance.crowd_coding.effort': FieldMeta(
    yamlPath: 'governance.crowd_coding.effort',
    jsonKey: 'governance.crowdCoding.effort',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Reasoning effort for crowd-coding turns. Null inherits the primary lane setting.',
    nullable: true,
  ),
  'governance.rate_limits.per_sender.messages': FieldMeta(
    yamlPath: 'governance.rate_limits.per_sender.messages',
    jsonKey: 'governance.rateLimits.perSender.messages',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Messages one sender may send inside the window. 0 lifts the limit.',
    min: 0,
  ),
  'governance.rate_limits.per_sender.window': FieldMeta(
    yamlPath: 'governance.rate_limits.per_sender.window',
    jsonKey: 'governance.rateLimits.perSender.window',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Length of the sliding window in minutes; YAML also accepts shorthand such as 5m or 1h.',
    alsoAccepts: ConfigFieldType.string,
    min: 1,
    max: 1440,
  ),
  'governance.rate_limits.per_sender.max_queued': FieldMeta(
    yamlPath: 'governance.rate_limits.per_sender.max_queued',
    jsonKey: 'governance.rateLimits.perSender.maxQueued',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Messages held back per sender once the limit is hit; further ones are dropped. 0 drops immediately.',
    min: 0,
  ),
  'governance.rate_limits.per_sender.max_pause_queued': FieldMeta(
    yamlPath: 'governance.rate_limits.per_sender.max_pause_queued',
    jsonKey: 'governance.rateLimits.perSender.maxPauseQueued',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Messages held back per sender while a turn is paused. 0 drops them.',
    min: 0,
  ),
  'governance.rate_limits.global.turns': FieldMeta(
    yamlPath: 'governance.rate_limits.global.turns',
    jsonKey: 'governance.rateLimits.global.turns',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Agent turns allowed inside the window across every sender. 0 lifts the limit.',
    min: 0,
  ),
  'governance.rate_limits.global.window': FieldMeta(
    yamlPath: 'governance.rate_limits.global.window',
    jsonKey: 'governance.rateLimits.global.window',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Length of the instance-wide sliding window in minutes; YAML also accepts shorthand such as 5m or 1h.',
    alsoAccepts: ConfigFieldType.string,
    min: 1,
    max: 1440,
  ),
  'governance.budget.daily_tokens': FieldMeta(
    yamlPath: 'governance.budget.daily_tokens',
    jsonKey: 'governance.budget.dailyTokens',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Token allowance per day across the instance. 0 means unlimited.',
    min: 0,
  ),
  'governance.budget.action': FieldMeta(
    yamlPath: 'governance.budget.action',
    jsonKey: 'governance.budget.action',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'What happens once the allowance is spent: refuse new turns, or only warn.',
    allowedValues: ['warn', 'block'],
  ),
  'governance.budget.timezone': FieldMeta(
    yamlPath: 'governance.budget.timezone',
    jsonKey: 'governance.budget.timezone',
    type: ConfigFieldType.string,
    mutability: ConfigMutability.restart,
    description: 'Zone whose midnight resets the allowance. Accepts UTC, UTC±N, and DST-aware IANA names.',
  ),
  'governance.loop_detection.enabled': FieldMeta(
    yamlPath: 'governance.loop_detection.enabled',
    jsonKey: 'governance.loopDetection.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description: 'Watch for a runaway agent and stop it. Off by default.',
  ),
  'governance.loop_detection.max_consecutive_turns': FieldMeta(
    yamlPath: 'governance.loop_detection.max_consecutive_turns',
    jsonKey: 'governance.loopDetection.maxConsecutiveTurns',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Consecutive turns tolerated before the action fires. 0 mutes this signal.',
    min: 0,
  ),
  'governance.loop_detection.max_tokens_per_minute': FieldMeta(
    yamlPath: 'governance.loop_detection.max_tokens_per_minute',
    jsonKey: 'governance.loopDetection.maxTokensPerMinute',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Token velocity tolerated before the action fires. 0 mutes this signal.',
    min: 0,
  ),
  'governance.loop_detection.velocity_window_minutes': FieldMeta(
    yamlPath: 'governance.loop_detection.velocity_window_minutes',
    jsonKey: 'governance.loopDetection.velocityWindowMinutes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Minutes the velocity average is computed over.',
    min: 1,
  ),
  'governance.loop_detection.max_consecutive_identical_tool_calls': FieldMeta(
    yamlPath: 'governance.loop_detection.max_consecutive_identical_tool_calls',
    jsonKey: 'governance.loopDetection.maxConsecutiveIdenticalToolCalls',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Repeated identical tool calls tolerated before the action fires. 0 mutes this signal.',
    min: 0,
  ),
  'governance.loop_detection.action': FieldMeta(
    yamlPath: 'governance.loop_detection.action',
    jsonKey: 'governance.loopDetection.action',
    type: ConfigFieldType.enum_,
    mutability: ConfigMutability.restart,
    description: 'What a detected runaway triggers: aborting the turn, or a warning only.',
    allowedValues: ['abort', 'warn'],
  ),
  'features.thread_binding.enabled': FieldMeta(
    yamlPath: 'features.thread_binding.enabled',
    jsonKey: 'features.threadBinding.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.restart,
    description:
        'Route messages in a bound thread straight to that task session, and post task notifications as new threads. '
        'Google Chat only — it is the one channel that carries a thread identity to bind.',
  ),
  'features.thread_binding.idle_timeout_minutes': FieldMeta(
    yamlPath: 'features.thread_binding.idle_timeout_minutes',
    jsonKey: 'features.threadBinding.idleTimeoutMinutes',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.restart,
    description: 'Minutes of thread inactivity before the binding is dropped. The sweep runs every five minutes, so removal can lag.',
    min: 1,
    max: 1440,
  ),
  'alerts.enabled': FieldMeta(
    yamlPath: 'alerts.enabled',
    jsonKey: 'alerts.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.reloadable,
    description: 'Deliver operational alerts to the configured targets. Off silences delivery, not the log line.',
  ),
  'alerts.cooldown_seconds': FieldMeta(
    yamlPath: 'alerts.cooldown_seconds',
    jsonKey: 'alerts.cooldownSeconds',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.reloadable,
    description: 'Seconds one alert type is suppressed after firing, so a flapping condition does not spam.',
    min: 1,
  ),
  'alerts.burst_threshold': FieldMeta(
    yamlPath: 'alerts.burst_threshold',
    jsonKey: 'alerts.burstThreshold',
    type: ConfigFieldType.int_,
    mutability: ConfigMutability.reloadable,
    description: 'Alerts inside the cooldown that collapse into one summary instead of separate messages.',
    min: 1,
  ),

  // --- Guards — enforcement switches and rule extensions ---
  // The two switches register readonly: guard enforcement is a deterministic
  // keep, so becoming describable must not hand an API caller a kill switch.
  'guards.enabled': FieldMeta(
    yamlPath: 'guards.enabled',
    jsonKey: 'guards.enabled',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.readonly,
    description: 'Master switch for the whole guard pipeline. On by default; read-only, because turning enforcement off is a YAML-and-restart decision, not an API call.',
  ),
  'guards.fail_open': FieldMeta(
    yamlPath: 'guards.fail_open',
    jsonKey: 'guards.failOpen',
    type: ConfigFieldType.bool_,
    mutability: ConfigMutability.readonly,
    description: 'Whether an unexpected guard failure warns instead of blocking. Fail-closed by default; read-only for the same reason as the master switch.',
  ),
  'guards.command.extra_blocked_patterns': FieldMeta(
    yamlPath: 'guards.command.extra_blocked_patterns',
    jsonKey: 'guards.command.extraBlockedPatterns',
    type: ConfigFieldType.stringList,
    mutability: ConfigMutability.readonly,
    description:
        'Regexes added to the built-in destructive-command set. An invalid pattern fails the guard build rather than '
        'being skipped silently.'
        'Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects.',
  ),
  'guards.command.extra_blocked_pipe_targets': FieldMeta(
    yamlPath: 'guards.command.extra_blocked_pipe_targets',
    jsonKey: 'guards.command.extraBlockedPipeTargets',
    type: ConfigFieldType.stringList,
    mutability: ConfigMutability.readonly,
    description:
        'Programs added to the built-in set that must never be piped into, such as an interpreter reading from a '
        'download.'
        'Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects.',
  ),
  'guards.file.extra_rules': FieldMeta(
    yamlPath: 'guards.file.extra_rules',
    jsonKey: 'guards.file.extraRules',
    type: ConfigFieldType.objectList,
    mutability: ConfigMutability.readonly,
    description:
        'Path rules added to the built-in protections. Two rules over one pattern with different levels fail the guard '
        'build.'
        'Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects.',
    entry: ObjectEntry(
      fields: {
        'pattern': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Glob the rule applies to, e.g. **/*.secret. Required and non-blank.',
        ),
        'level': EntryFieldMeta(
          type: ConfigFieldType.enum_,
          description: 'How far access is cut: no_access blocks everything, read_only blocks writes and deletes, no_delete blocks deletes only.',
          allowedValues: ['no_access', 'read_only', 'no_delete'],
        ),
      },
    ),
  ),
  'guards.network.extra_allowed_domains': FieldMeta(
    yamlPath: 'guards.network.extra_allowed_domains',
    jsonKey: 'guards.network.extraAllowedDomains',
    type: ConfigFieldType.stringList,
    mutability: ConfigMutability.readonly,
    description:
        'Hosts added to the built-in outbound allowlist. Every fetch target an MCP deployment needs must be listed '
        'here.'
        'Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects.',
  ),
  'guards.network.extra_exfil_patterns': FieldMeta(
    yamlPath: 'guards.network.extra_exfil_patterns',
    jsonKey: 'guards.network.extraExfilPatterns',
    type: ConfigFieldType.stringList,
    mutability: ConfigMutability.readonly,
    description:
        'Regexes added to the built-in exfiltration detectors. An invalid pattern fails the guard build.'
        'Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects.',
  ),
  'guards.network.agent_overrides': FieldMeta(
    yamlPath: 'guards.network.agent_overrides',
    jsonKey: 'guards.network.agentOverrides',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.readonly,
    description:
        'Per-logical-agent outbound widenings keyed by agent id. They add to the allowlist and never narrow it.'
        'Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects.',
    entry: ObjectEntry(
      fields: {
        'extra_domains': EntryFieldMeta(
          type: ConfigFieldType.stringList,
          description: 'Hosts this agent turns may additionally reach. An empty list drops the override entirely.',
        ),
      },
    ),
  ),

  // --- Alerts — delivery targets and routing ---
  // Reloadable, matching the alert router: it swaps the whole alerts section,
  // targets included, at runtime.
  'alerts.targets': FieldMeta(
    yamlPath: 'alerts.targets',
    jsonKey: 'alerts.targets',
    type: ConfigFieldType.objectList,
    mutability: ConfigMutability.reloadable,
    description: 'Where alerts are delivered. An empty list silences delivery even while alerting is on.',
    entry: ObjectEntry(
      fields: {
        'channel': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Channel the alert is sent over, e.g. signal. Required and non-blank, or the target is skipped.',
        ),
        'recipient': EntryFieldMeta(
          type: ConfigFieldType.string,
          description: 'Address on that channel, e.g. a phone number or space id. Required and non-blank, or the target is skipped.',
        ),
      },
    ),
  ),
  'alerts.routes': FieldMeta(
    yamlPath: 'alerts.routes',
    jsonKey: 'alerts.routes',
    type: ConfigFieldType.objectMap,
    mutability: ConfigMutability.reloadable,
    description: 'Which targets each alert type reaches, keyed by alert type. While this map is empty every alert type reaches every configured target; once it holds any entry it acts as an allowlist and a type with no entry reaches nothing.',
    entry: ValueEntry(
      value: EntryFieldMeta(
        type: ConfigFieldType.stringList,
        description: 'Recipients this alert type is delivered to. A non-list value is skipped with a warning.',
      ),
    ),
  ),
};
