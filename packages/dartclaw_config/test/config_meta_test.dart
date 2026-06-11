import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('ConfigMeta', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    test('registry is complete and internally consistent', () {
      expect(ConfigMeta.fields, isNotEmpty);
      for (final entry in ConfigMeta.fields.entries) {
        expect(entry.value.yamlPath, isNotEmpty, reason: 'yamlPath empty for ${entry.key}');
        expect(entry.value.jsonKey, isNotEmpty, reason: 'jsonKey empty for ${entry.key}');
        expect(entry.key, entry.value.yamlPath, reason: 'key mismatch for ${entry.key}');
      }

      final expectedFields = {
        'scheduling.heartbeat.enabled',
        'workspace.git_sync.enabled',
        'workspace.git_sync.push_enabled',
        'port',
        'host',
        'data_dir',
        'source_dir',
        'static_dir',
        'templates_dir',
        'workflow.workspace_dir',
        'worker_timeout',
        'agent.model',
        'agent.max_turns',
        'agent.effort',
        'auth.cookie_secure',
        'auth.trusted_proxies',
        'tasks.max_concurrent',
        'tasks.artifact_retention_days',
        'tasks.worktree.base_ref',
        'tasks.worktree.stale_timeout_hours',
        'tasks.worktree.merge_strategy',
        'tasks.completion_action',
        'concurrency.max_parallel_turns',
        'guard_audit.max_retention_days',
        'sessions.reset_hour',
        'sessions.idle_timeout_minutes',
        'logging.level',
        'logging.format',
        'scheduling.heartbeat.interval_minutes',
        'context.reserve_tokens',
        'context.max_result_bytes',
        'context.warning_threshold',
        'context.exploration_summary_threshold',
        'context.compact_instructions',
        'search.backend',
        'search.qmd.host',
        'search.qmd.port',
        'search.default_depth',
        'logging.file',
        'logging.redact_patterns',
        'guards.content.enabled',
        'guards.content.classifier',
        'guards.content.model',
        'guards.content.max_bytes',
        'guards.input_sanitizer.enabled',
        'guards.input_sanitizer.channels_only',
        'memory.pruning.enabled',
        'memory.pruning.archive_after_days',
        'memory.pruning.schedule',
        'usage.budget_warning_tokens',
        'usage.max_file_size_bytes',
        'channels.google_chat.enabled',
        'channels.google_chat.service_account',
        'channels.google_chat.oauth_credentials',
        'channels.google_chat.audience.type',
        'channels.google_chat.audience.value',
        'channels.google_chat.webhook_path',
        'channels.google_chat.bot_user',
        'channels.google_chat.typing_indicator',
        'channels.google_chat.quote_reply',
        'channels.google_chat.dm_access',
        'channels.google_chat.dm_allowlist',
        'channels.google_chat.group_access',
        'channels.google_chat.group_allowlist',
        'channels.google_chat.require_mention',
        'channels.whatsapp.task_trigger.enabled',
        'channels.whatsapp.task_trigger.prefix',
        'channels.whatsapp.task_trigger.default_type',
        'channels.whatsapp.task_trigger.auto_start',
        'channels.signal.task_trigger.enabled',
        'channels.signal.task_trigger.prefix',
        'channels.signal.task_trigger.default_type',
        'channels.signal.task_trigger.auto_start',
        'channels.google_chat.task_trigger.enabled',
        'channels.google_chat.task_trigger.prefix',
        'channels.google_chat.task_trigger.default_type',
        'channels.google_chat.task_trigger.auto_start',
        'channels.google_chat.pubsub.project_id',
        'channels.google_chat.pubsub.subscription',
        'channels.google_chat.pubsub.poll_interval_seconds',
        'channels.google_chat.pubsub.max_messages_per_pull',
        'channels.google_chat.space_events.enabled',
        'channels.google_chat.space_events.pubsub_topic',
        'channels.google_chat.space_events.event_types',
        'channels.google_chat.space_events.include_resource',
        'channels.google_chat.feedback.enabled',
        'channels.google_chat.feedback.min_feedback_delay',
        'channels.google_chat.feedback.status_interval',
        'channels.google_chat.feedback.status_style',
        'governance.queue_strategy',
        'harness.turn_monitor.wait_warning_after',
        'harness.turn_monitor.stuck_after',
        'governance.turn_progress.stall_timeout',
        'governance.turn_progress.stall_action',
        'governance.crowd_coding.model',
        'governance.crowd_coding.effort',
        'governance.rate_limits.per_sender.max_queued',
        'governance.rate_limits.per_sender.max_pause_queued',
        'advisor.enabled',
        'advisor.model',
        'advisor.effort',
        'advisor.triggers',
        'advisor.periodic_interval_minutes',
        'advisor.max_window_turns',
        'advisor.max_prior_reflections',
        'alerts.enabled',
        'alerts.cooldown_seconds',
        'alerts.burst_threshold',
        'delegation.enabled',
        'delegation.agents',
        'delegation.max_budget_tokens',
        'delegation.budget_accounting',
        'delegation.rate_limit.max_per_minute',
        'gateway.auth_mode',
        'gateway.token',
        'gateway.hsts',
      };
      for (final field in expectedFields) {
        expect(ConfigMeta.fields, contains(field), reason: field);
      }
      expect(ConfigMeta.fields, isNot(contains('memory_max_bytes')));
    });

    test('field metadata roots are backed by built-in keys or registered extension parsers', () {
      ensureGitHubWebhookConfigRegistered();
      final metadataRoots = ConfigMeta.fields.keys.map((path) => path.split('.').first).toSet();
      final parserRoots = {
        ...DartclawConfig.knownTopLevelKeysForTesting(),
        ...DartclawConfig.registeredExtensionKeysForTesting(),
      };

      expect(metadataRoots.difference(parserRoots), isEmpty);
      expect(DartclawConfig.registeredExtensionKeysForTesting(), contains('github'));
    });

    test('mutability and type classification matches config surface contracts', () {
      final mutabilityCases = <({String field, ConfigMutability mutability})>[
        (field: 'scheduling.heartbeat.enabled', mutability: ConfigMutability.live),
        (field: 'workspace.git_sync.enabled', mutability: ConfigMutability.live),
        (field: 'workspace.git_sync.push_enabled', mutability: ConfigMutability.live),
        (field: 'sessions.dm_scope', mutability: ConfigMutability.live),
        (field: 'sessions.group_scope', mutability: ConfigMutability.live),
        (field: 'alerts.enabled', mutability: ConfigMutability.reloadable),
        (field: 'alerts.cooldown_seconds', mutability: ConfigMutability.reloadable),
        (field: 'alerts.burst_threshold', mutability: ConfigMutability.reloadable),
        (field: 'port', mutability: ConfigMutability.restart),
        (field: 'agent.model', mutability: ConfigMutability.restart),
        (field: 'auth.cookie_secure', mutability: ConfigMutability.restart),
        (field: 'auth.trusted_proxies', mutability: ConfigMutability.restart),
        (field: 'gateway.hsts', mutability: ConfigMutability.restart),
        (field: 'tasks.artifact_retention_days', mutability: ConfigMutability.restart),
        (field: 'tasks.completion_action', mutability: ConfigMutability.restart),
        (field: 'guard_audit.max_retention_days', mutability: ConfigMutability.restart),
        (field: 'context.exploration_summary_threshold', mutability: ConfigMutability.restart),
        (field: 'context.compact_instructions', mutability: ConfigMutability.restart),
        (field: 'workflow.workspace_dir', mutability: ConfigMutability.restart),
        (field: 'delegation.enabled', mutability: ConfigMutability.restart),
        (field: 'gateway.auth_mode', mutability: ConfigMutability.readonly),
        (field: 'gateway.token', mutability: ConfigMutability.readonly),
        (field: 'channels.whatsapp.task_trigger.enabled', mutability: ConfigMutability.restart),
        (field: 'channels.signal.task_trigger.prefix', mutability: ConfigMutability.restart),
        (field: 'channels.google_chat.task_trigger.default_type', mutability: ConfigMutability.restart),
        (field: 'channels.google_chat.task_trigger.auto_start', mutability: ConfigMutability.restart),
        (field: 'advisor.enabled', mutability: ConfigMutability.restart),
      ];
      for (final (:field, :mutability) in mutabilityCases) {
        expect(ConfigMeta.fields[field]!.mutability, mutability, reason: field);
      }

      final typeCases = <({String field, ConfigFieldType type})>[
        (field: 'delegation.agents', type: ConfigFieldType.objectList),
        (field: 'context.warning_threshold', type: ConfigFieldType.int_),
        (field: 'context.exploration_summary_threshold', type: ConfigFieldType.int_),
        (field: 'context.compact_instructions', type: ConfigFieldType.string),
        (field: 'channels.whatsapp.task_trigger.default_type', type: ConfigFieldType.string),
        (field: 'channels.signal.task_trigger.default_type', type: ConfigFieldType.string),
        (field: 'channels.google_chat.task_trigger.default_type', type: ConfigFieldType.string),
      ];
      for (final (:field, :type) in typeCases) {
        expect(ConfigMeta.fields[field]!.type, type, reason: field);
      }

      expect(ConfigMeta.fields['delegation.budget_accounting']!.allowedValues, [
        'provider_reported',
        'estimate_if_unreported',
      ]);
      expect(ConfigMeta.fields['context.warning_threshold']!.min, 50);
      expect(ConfigMeta.fields['context.warning_threshold']!.max, 99);
      expect(ConfigMeta.fields['context.exploration_summary_threshold']!.min, 1000);
      expect(ConfigMeta.fields['context.compact_instructions']!.nullable, true);
      expect(ConfigMeta.fields['advisor.periodic_interval_minutes']!.min, 1);
      expect(ConfigMeta.fields['advisor.max_window_turns']!.max, 100);
      expect(ConfigMeta.fields['advisor.max_prior_reflections']!.max, 20);
    });

    test('JSON key mapping is complete and stable for representative fields', () {
      expect(ConfigMeta.byJsonKey.length, ConfigMeta.fields.length);
      final cases = {
        'scheduling.heartbeat.interval_minutes': 'scheduling.heartbeat.intervalMinutes',
        'agent.max_turns': 'agent.maxTurns',
        'agent.provider': 'agent.provider',
        'concurrency.max_parallel_turns': 'concurrency.maxParallelTurns',
        'guard_audit.max_retention_days': 'guardAudit.maxRetentionDays',
        'tasks.artifact_retention_days': 'tasks.artifactRetentionDays',
        'tasks.completion_action': 'tasks.completionAction',
        'channels.google_chat.oauth_credentials': 'channels.googleChat.oauthCredentials',
        'source_dir': 'sourceDir',
        'static_dir': 'staticDir',
        'templates_dir': 'templatesDir',
        'workflow.workspace_dir': 'workflow.workspaceDir',
        'workflow.defaults.reviewer.model': 'workflow.defaults.reviewer.model',
        'channels.google_chat.quote_reply': 'channels.googleChat.quoteReplyMode',
        'channels.google_chat.feedback.status_interval': 'channels.googleChat.feedback.statusInterval',
        'governance.turn_progress.stall_timeout': 'governance.turnProgress.stallTimeout',
        'harness.turn_monitor.wait_warning_after': 'harness.turnMonitor.waitWarningAfter',
      };
      for (final entry in cases.entries) {
        expect(ConfigMeta.fields[entry.key]!.jsonKey, entry.value, reason: entry.key);
      }

      final meta = ConfigMeta.byJsonKey['scheduling.heartbeat.intervalMinutes'];
      expect(meta, isNotNull);
      expect(meta!.yamlPath, 'scheduling.heartbeat.interval_minutes');
    });

    test('helper APIs report known, writable, and mutability-filtered fields', () {
      expect(ConfigMeta.isKnown('port'), isTrue);
      expect(ConfigMeta.isKnown('nonexistent'), isFalse);

      for (final field in [
        'port',
        'scheduling.heartbeat.enabled',
        'channels.whatsapp.task_trigger.enabled',
        'channels.signal.task_trigger.prefix',
        'channels.google_chat.task_trigger.default_type',
        'agent.provider',
        'workflow.workspace_dir',
        'workflow.defaults.workflow.provider',
      ]) {
        expect(ConfigMeta.isWritable(field), isTrue, reason: field);
      }
      expect(ConfigMeta.isWritable('gateway.auth_mode'), isFalse);
      expect(ConfigMeta.isWritable('nonexistent'), isFalse);

      final live = ConfigMeta.forMutability(ConfigMutability.live).map((field) => field.yamlPath).toSet();
      expect(live, hasLength(6));
      expect(
        live,
        containsAll([
          'sessions.dm_scope',
          'sessions.group_scope',
          'scheduling.heartbeat.enabled',
          'workspace.git_sync.enabled',
          'workspace.git_sync.push_enabled',
          'context.warning_threshold',
        ]),
      );

      final readonly = ConfigMeta.forMutability(ConfigMutability.readonly).map((field) => field.yamlPath).toSet();
      expect(readonly, hasLength(5));
      expect(
        readonly,
        containsAll([
          'gateway.auth_mode',
          'gateway.token',
          'channels.google_chat.service_account',
          'channels.google_chat.audience.type',
          'channels.google_chat.audience.value',
        ]),
      );
    });
  });
}
