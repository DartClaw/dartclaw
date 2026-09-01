import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

part 'support/config_dispositions.dart';

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
        'workspace.git_sync.interval_minutes',
        'port',
        'host',
        'data_dir',
        'source_dir',
        'static_dir',
        'templates_dir',
        'workflow.workspace_dir',
        'workflow.approvals',
        'workflow.runtime_artifacts_retention.mode',
        'workflow.runtime_artifacts_retention.prune_after_days',
        'agent.model',
        'agent.max_turns',
        'agent.execution',
        'agent.effort',
        'auth.cookie_secure',
        'auth.trusted_proxies',
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
        'context.compact_instructions',
        'search.backend',
        'search.qmd.host',
        'search.qmd.port',
        'search.default_depth',
        'mcp_servers',
        'logging.file',
        'logging.redact_patterns',
        'guards.content.enabled',
        'guards.content.classifier',
        'guards.content.model',
        'guards.content.max_bytes',
        'memory.pruning.enabled',
        'memory.pruning.archive_after_days',
        'memory.pruning.schedule',
        'memory.journal.enabled',
        'memory.journal.schedule',
        'memory.curation.enabled',
        'memory.curation.schedule',
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
        'governance.turn_limits.stall_timeout',
        'governance.turn_limits.stall_action',
        'governance.turn_limits.turn_timeout',
        'governance.crowd_coding.model',
        'governance.crowd_coding.effort',
        'governance.rate_limits.per_sender.max_queued',
        'governance.rate_limits.per_sender.max_pause_queued',
        'alerts.enabled',
        'alerts.cooldown_seconds',
        'alerts.burst_threshold',
        'gateway.auth_mode',
        'gateway.token',
        'gateway.hsts',
      };
      for (final field in expectedFields) {
        expect(ConfigMeta.fields, contains(field), reason: field);
      }
      expect(ConfigMeta.fields, isNot(contains('memory_max_bytes')));
      expect(ConfigMeta.fields, isNot(contains('guards.input_sanitizer.enabled')));
      expect(ConfigMeta.fields.keys.where((field) => field.startsWith('advisor.')), isEmpty);
    });

    // The reload-tier disposition of the heartbeat/git-sync fold, by name. A later
    // fold cannot move one of these tiers without editing this table.
    test('the heartbeat and git-sync keys carry their decided reload tiers', () {
      const disposition = <String, ConfigMutability>{
        // Preserved: ScheduleService.pauseJob/resumeJob is a live service API.
        'scheduling.heartbeat.enabled': ConfigMutability.live,
        // Declared deviation: a job's interval is fixed at registration.
        'scheduling.heartbeat.interval_minutes': ConfigMutability.restart,
        // Upgraded from live-but-dead to live-and-applied.
        'workspace.git_sync.enabled': ConfigMutability.live,
        'workspace.git_sync.push_enabled': ConfigMutability.live,
        // New key, restart for the same structural reason as the heartbeat interval.
        'workspace.git_sync.interval_minutes': ConfigMutability.restart,
      };
      for (final entry in disposition.entries) {
        final meta = ConfigMeta.fields[entry.key];
        expect(meta, isNotNull, reason: entry.key);
        expect(meta!.mutability, entry.value, reason: entry.key);
      }
      expect(ConfigMeta.fields['workspace.git_sync.interval_minutes']!.min, 1);
      expect(ConfigMeta.fields['workspace.git_sync.interval_minutes']!.max, 1440);
    });

    test('the context section registers exactly the keys the runtime still honours', () {
      expect(
        ConfigMeta.fields.keys.where((key) => key.startsWith('context.')),
        unorderedEquals(const [
          'context.reserve_tokens',
          'context.max_result_bytes',
          'context.warning_threshold',
          'context.compact_instructions',
          'context.identifier_preservation',
          'context.identifier_instructions',
        ]),
      );
      // The tool-result byte cap survived the summarizer deletion, and stays operator-editable.
      expect(ConfigMeta.fields['context.max_result_bytes']!.mutability, ConfigMutability.reloadable);
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
        (field: 'context.compact_instructions', mutability: ConfigMutability.restart),
        (field: 'workflow.workspace_dir', mutability: ConfigMutability.restart),
        (field: 'workflow.approvals', mutability: ConfigMutability.restart),
        (field: 'workflow.runtime_artifacts_retention.mode', mutability: ConfigMutability.restart),
        (field: 'workflow.runtime_artifacts_retention.prune_after_days', mutability: ConfigMutability.restart),
        (field: 'mcp_servers', mutability: ConfigMutability.restart),
        (field: 'gateway.auth_mode', mutability: ConfigMutability.readonly),
        (field: 'gateway.token', mutability: ConfigMutability.readonly),
      ];
      for (final (:field, :mutability) in mutabilityCases) {
        expect(ConfigMeta.fields[field]!.mutability, mutability, reason: field);
      }

      final typeCases = <({String field, ConfigFieldType type})>[
        (field: 'mcp_servers', type: ConfigFieldType.objectMap),
        (field: 'context.warning_threshold', type: ConfigFieldType.int_),
        (field: 'context.compact_instructions', type: ConfigFieldType.string),
      ];
      for (final (:field, :type) in typeCases) {
        expect(ConfigMeta.fields[field]!.type, type, reason: field);
      }

      expect(ConfigMeta.fields['workflow.approvals']!.allowedValues, ['manual', 'auto-on-stall', 'auto']);
      expect(ConfigMeta.fields['workflow.runtime_artifacts_retention.mode']!.allowedValues, ['warn', 'enforce']);
      expect(ConfigMeta.fields['workflow.runtime_artifacts_retention.prune_after_days']!.min, 0);
      expect(ConfigMeta.fields['context.warning_threshold']!.min, 50);
      expect(ConfigMeta.fields['context.warning_threshold']!.max, 99);
      expect(ConfigMeta.fields['context.compact_instructions']!.nullable, true);
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
        'workflow.approvals': 'workflow.approvals',
        'workflow.runtime_artifacts_retention.prune_after_days': 'workflow.runtimeArtifactsRetention.pruneAfterDays',
        'mcp_servers': 'mcpServers',
        'workflow.defaults.reviewer.model': 'workflow.defaults.reviewer.model',
        'channels.google_chat.quote_reply': 'channels.googleChat.quoteReplyMode',
        'channels.google_chat.feedback.status_interval': 'channels.googleChat.feedback.statusInterval',
        'governance.turn_limits.stall_timeout': 'governance.turnLimits.stallTimeout',
        'governance.turn_limits.turn_timeout': 'governance.turnLimits.turnTimeout',
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
        'agent.provider',
        'mcp_servers',
        'workflow.workspace_dir',
        'workflow.approvals',
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

      // Describable, deliberately not editable. Pinned as an exact set: a field
      // silently leaving it is how absence-as-access-control gets lost.
      final readonly = ConfigMeta.forMutability(ConfigMutability.readonly).map((field) => field.yamlPath).toSet();
      expect(
        readonly,
        unorderedEquals(const [
          'gateway.auth_mode',
          'gateway.token',
          'gateway.mcp_clients',
          'channels.google_chat.service_account',
          'channels.google_chat.audience.type',
          'channels.google_chat.audience.value',
          // Open container: written wholesale, so it would carry the three above past their own refusal.
          'channels',
          // Secret material.
          'credentials',
          'search.providers',
          // Guard enforcement, and the rule extensions the guard-editor
          // endpoints own writes to.
          'guards.enabled',
          'guards.fail_open',
          'guards.command.extra_blocked_patterns',
          'guards.command.extra_blocked_pipe_targets',
          'guards.file.extra_rules',
          'guards.network.extra_allowed_domains',
          'guards.network.extra_exfil_patterns',
          'guards.network.agent_overrides',
          // Placement.
          'container.enabled',
          'tasks.execution',
          // Host-filesystem reach.
          'projects.allowApiLocalPath',
          'projects.localPathAllowlist',
          // Would create scheduled jobs through the door the config API closes.
        ]),
      );
    });

    test('every key the container parser reads is described in the registry', () {
      // The registry is the sole schema source: a key the parser accepts and
      // the registry does not describe is invisible to config get/set, the
      // config API and the settings page.
      for (final key in ContainerConfig.knownKeys) {
        final meta = ConfigMeta.fields['container.$key'];
        expect(meta, isNotNull, reason: 'container.$key is parsed but unregistered');
        expect(meta!.description.trim(), isNotEmpty);
        expect(
          meta.mutability,
          anyOf(ConfigMutability.restart, ConfigMutability.readonly),
          reason: 'the container section is restart-tier; nothing here hot-reloads',
        );
      }
    });

    test('every field carries a description an operator can act on', () {
      for (final meta in ConfigMeta.fields.values) {
        expect(meta.description.trim(), isNotEmpty, reason: 'blank description for ${meta.yamlPath}');
        expect(
          _informativeWords(meta.description, meta.yamlPath),
          isNotEmpty,
          reason: '${meta.yamlPath} only restates its own key: "${meta.description}"',
        );
      }

      for (final meta in ConfigMeta.fields.values) {
        for (final field in _entryFieldsOf(meta.entry).entries) {
          expect(
            field.value.description.trim(),
            isNotEmpty,
            reason: 'blank description for ${meta.yamlPath} entry field ${field.key}',
          );
        }
      }
    });

    test('an object-valued field answers what one entry may contain without naming its path', () {
      // A consumer holding only the FieldMeta switches on the shape, never on
      // the field's yamlPath.
      String shapeKind(FieldMeta meta) => switch (meta.entry) {
        ObjectEntry() => 'object',
        ValueEntry() => 'value',
        OpaqueEntry() => 'opaque',
        null => 'none',
      };

      expect(shapeKind(ConfigMeta.fields['github.triggers']!), 'object');
      expect(
        _entryFieldsOf(ConfigMeta.fields['github.triggers']!.entry).keys,
        unorderedEquals(const ['event', 'actions', 'labels', 'workflow']),
      );

      expect(shapeKind(ConfigMeta.fields['alerts.targets']!), 'object');
      expect(
        _entryFieldsOf(ConfigMeta.fields['alerts.targets']!.entry).keys,
        unorderedEquals(const ['channel', 'recipient']),
      );

      final routes = ConfigMeta.fields['alerts.routes']!.entry;
      expect(routes, isA<ValueEntry>());
      expect((routes! as ValueEntry).value.type, ConfigFieldType.stringList);

      final mcp = _entryFieldsOf(ConfigMeta.fields['mcp_servers']!.entry);
      expect(mcp.keys, containsAll(const ['command', 'url', 'network_class', 'credential']));
      expect(mcp['command']!.nullable, isTrue);
      expect(mcp['network_class']!.allowedValues, const ['local', 'private', 'public']);

      // Every object-typed field declares a shape, and no scalar field carries one.
      for (final meta in ConfigMeta.fields.values) {
        final isObject = meta.type == ConfigFieldType.objectList || meta.type == ConfigFieldType.objectMap;
        expect(isObject || meta.entry == null, isTrue, reason: '${meta.yamlPath} is scalar but declares an entry');
        expect(
          !isObject || meta.entry != null,
          isTrue,
          reason: '${meta.yamlPath} is object-valued with no entry shape',
        );
      }
    });

    test('alerts.targets and alerts.routes are registered at the tier the alert router applies', () {
      for (final path in const ['alerts.targets', 'alerts.routes']) {
        final meta = ConfigMeta.fields[path];
        expect(meta, isNotNull, reason: '$path is read at load and must be registered');
        expect(meta!.mutability, ConfigMutability.reloadable, reason: path);
        expect(meta.entry, isNotNull, reason: path);
        expect(ConfigMeta.isWritable(path), isTrue, reason: path);
      }
    });

    test('guard enforcement and credential material are described but not editable', () {
      for (final path in const ['guards.enabled', 'guards.fail_open', 'credentials', 'channels']) {
        expect(ConfigMeta.isKnown(path), isTrue, reason: path);
        expect(ConfigMeta.isWritable(path), isFalse, reason: path);
      }
      // Nothing under credentials is settable either — no per-entry path is registered.
      expect(ConfigMeta.fields.keys.where((path) => path.startsWith('credentials.')), isEmpty);
      expect(ConfigMeta.isWritable('credentials.anthropic.api_key'), isFalse);
    });

    test('every enum-typed field declares the set it is checked against', () {
      // `FieldConstraints.evaluate` dereferences `allowedValues` for an `enum_`
      // field; a declaration without one would crash the config API instead of
      // refusing the write.
      expect(
        ConfigMeta.fields.values
            .where((field) => field.type == ConfigFieldType.enum_ && field.allowedValues == null)
            .map((field) => field.yamlPath),
        isEmpty,
      );
    });

    test('no field declares an upper bound without a lower one', () {
      // `FieldConstraints` applies `min` and `max` independently but renders
      // only the both-bounds and min-only wordings today; a max-only field
      // would ship a sentence no test has ever seen.
      expect(
        ConfigMeta.fields.values.where((field) => field.max != null && field.min == null).map((f) => f.yamlPath),
        isEmpty,
      );
    });

    test('every top-level key the parser accepts is registered or recorded as tolerated legacy', () {
      ensureGitHubWebhookConfigRegistered();
      final roots = ConfigMeta.fields.keys.map((path) => path.split('.').first).toSet();
      final tolerated = ConfigMeta.toleratedLegacyKeys.keys.map((path) => path.split('.').first).toSet();

      final unrepresented = DartclawConfig.knownTopLevelKeysForTesting()
          .where((key) => !roots.contains(key) && !tolerated.contains(key))
          .toSet();
      expect(unrepresented, isEmpty, reason: 'accepted top-level sections with no registered field: $unrepresented');
    });

    test('the tolerated-legacy accept-set has exactly the membership it declares', () {
      // Asserted against a literal, so every future row is a deliberate edit
      // rather than something a failing test talked the set into accepting.
      expect(
        ConfigMeta.toleratedLegacyKeys.keys,
        unorderedEquals(const [
          'andthen',
          'delegation',
          'tasks.max_concurrent',
          'memory_max_bytes',
          'guard_audit.max_entries',
          'workflow.execution_mode',
          'channels.whatsapp.task_trigger',
          'channels.signal.task_trigger',
          'channels.google_chat.task_trigger',
          'container.mount_allowlist',
          'container.mounts',
          'container.extra_args',
          'automation.scheduled_tasks',
          'channels.google_chat.space_events.auth_mode',
          'context.exploration_summary_threshold',
          'advisor',
          'guards.input_sanitizer',
          'canvas',
          'crowd_coding',
        ]),
      );
      for (final entry in ConfigMeta.toleratedLegacyKeys.entries) {
        expect(entry.value.path, entry.key, reason: 'key mismatch for ${entry.key}');
        expect(entry.value.replacement.trim(), isNotEmpty, reason: entry.key);
      }
    });

    test('every accept-set row is announced in the CHANGELOG, so a deferred break stays visible', () async {
      final changelog = await _repoFile('CHANGELOG.md');
      final deprecated = _unreleasedDeprecatedSection(changelog);
      expect(deprecated, isNotEmpty, reason: 'the Unreleased ### Deprecated section could not be read');

      for (final path in ConfigMeta.toleratedLegacyKeys.keys) {
        expect(deprecated, contains('`$path`'), reason: '$path has no CHANGELOG deprecation row');
      }

      // The gate has to be able to fail, on the two ways it realistically can:
      // a row added without an entry, and a released section standing in for
      // the unreleased one after a version bump.
      final unannounced = {
        ...ConfigMeta.toleratedLegacyKeys,
        'invented.row': const ToleratedLegacyKey(
          path: 'invented.row',
          match: LegacyKeyMatch.exact,
          replacement: 'Never announced anywhere.',
        ),
      };
      expect(unannounced.keys.where((path) => !deprecated.contains('`$path`')), ['invented.row']);
      expect(
        _unreleasedDeprecatedSection(changelog.replaceFirst('## [Unreleased]', '## [9.9.9] - 2099-01-01')),
        isEmpty,
        reason: 'the slice must not fall through to a released section',
      );
    });

    test('keys the loader tolerates but ignores are recorded as such, not as fields', () {
      for (final path in const ['andthen', 'delegation', 'tasks.max_concurrent', 'memory_max_bytes']) {
        expect(ConfigMeta.toleratedLegacyKeys, contains(path), reason: path);
        expect(ConfigMeta.fields, isNot(contains(path)), reason: path);
      }
      expect(ConfigMeta.fields.keys.any((path) => path.startsWith('andthen.')), isFalse);

      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml'
            ? 'andthen:\n  git_url: https://example.com/andthen\ndelegation:\n  enabled: true\n'
            : null,
        env: const {'HOME': '/home/user'},
      );
      expect(config.warnings, contains(contains('DartClaw no longer provisions AndThen skills')));
      expect(config.warnings, contains(contains('Ignoring removed delegation config')));
    });

    test('retired task-trigger blocks warn and load while a misspelled block fails', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) => path == 'dartclaw.yaml'
            ? 'channels:\n  google_chat:\n    task_trigger:\n      enabled: true\n      prefix: "task:"\n      default_type: research\n      auto_start: true\n'
            : null,
        env: const {'HOME': '/home/user'},
      );

      expect(config.warnings, contains(contains('channels.google_chat.task_trigger')));
      expect(config.warnings, contains(contains('task_create')));
      expect(
        () => DartclawConfig.load(
          configPath: 'dartclaw.yaml',
          fileReader: (path) =>
              path == 'dartclaw.yaml' ? 'channels:\n  google_chat:\n    task_triggr:\n      enabled: true\n' : null,
          env: const {'HOME': '/home/user'},
        ),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('task_triggr'))),
      );
    });

    test('channel-specific retry policies are unknown while the shared policy remains registered', () {
      for (final channel in const ['whatsapp', 'signal', 'google_chat']) {
        for (final key in const ['max_attempts', 'base_delay_ms', 'jitter_factor']) {
          expect(ConfigMeta.isKnown('channels.$channel.retry_policy.$key'), isFalse, reason: '$channel.$key');
        }
      }

      for (final key in const ['max_attempts', 'base_delay_ms', 'jitter_factor']) {
        expect(ConfigMeta.isKnown('channels.retry_policy.$key'), isTrue, reason: key);
      }
    });

    test('channel-specific retry policies fail config loading', () {
      for (final channel in const ['whatsapp', 'signal', 'google_chat']) {
        final path = 'channels.$channel.retry_policy';
        expect(
          () => DartclawConfig.load(
            configPath: 'dartclaw.yaml',
            fileReader: (filePath) => filePath == 'dartclaw.yaml'
                ? 'channels:\n  $channel:\n    retry_policy:\n      max_attempts: 3\n      base_delay_ms: 1000\n      jitter_factor: 0.2\n'
                : null,
            env: const {'HOME': '/home/user'},
          ),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains(path))),
          reason: path,
        );
      }
    });

    test('the shared non-retry channel keys are registered for every channel that parses them', () {
      // One reader in `CommonChannelFields.fromYaml` runs for all three
      // channels, so a key registered for one and not another is a config that
      // boots on WhatsApp and refuses to boot on Google Chat. `response_prefix`
      // is read only where a default is supplied, but it is registered
      // everywhere because the sweep does not know that.
      const shared = [
        'enabled',
        'dm_access',
        'group_access',
        'dm_allowlist',
        'group_allowlist',
        'mention_patterns',
        'require_mention',
        'response_prefix',
        'max_chunk_size',
      ];
      final missing = [
        for (final channel in const ['whatsapp', 'signal', 'google_chat'])
          for (final key in shared)
            if (!ConfigMeta.isKnown('channels.$channel.$key')) 'channels.$channel.$key',
      ];
      expect(missing, isEmpty, reason: 'shared channel keys the parser reads but the registry does not describe');
    });

    test('every leaf in the operator guide resolves to a field or an enclosing entry shape', () async {
      // Reasoned exclusions: guide-documented paths with no parser consumer.
      // Empty since the load sweep became fatal — a documented leaf nothing
      // describes is now a config an operator can copy and fail to boot with,
      // so an exclusion here would be a trap rather than a note.
      const guideOnly = <String>{};

      final leaves = _guideConfigLeaves(await _guideSource());
      expect(leaves, hasLength(greaterThan(150)), reason: 'the guide Full Config Reference block could not be read');

      // The gate has to be able to fail: an unregistered leaf must not resolve
      // through its enclosing section, and an entry shape must name the leaf
      // rather than merely exist.
      expect(_resolves('channels.whatsapp.not_a_key'), isFalse);
      expect(_resolves('channels.discord.enabled'), isFalse);
      expect(_resolves('mcp_servers.example.not_a_key'), isFalse);
      expect(_resolves('projects.my-app.not_a_key'), isFalse);

      final unresolved = leaves.where((leaf) => !guideOnly.contains(leaf) && !_resolves(leaf)).toSet();
      expect(unresolved, isEmpty, reason: 'guide leaves answerable from nowhere: $unresolved');

      for (final leaf in guideOnly) {
        expect(leaves, contains(leaf), reason: '$leaf is excluded but the guide no longer documents it');
      }
    });

    test('every declaration the loader also decides carries a disposition, and drifting from it fails', () {
      // The bound-divergence roster, asserted against a literal rather than
      // against the table it pins, so editing the table alone cannot move it.
      expect(
        _boundDivergences.keys,
        unorderedEquals(const [
          'knowledge.inbox.interval_minutes',
          'knowledge.inbox.max_bytes',
          'knowledge.inbox.retry_attempts',
          'knowledge.inbox.processed_retention_days',
          'knowledge.wiki_lint.interval_minutes',
          'gateway.auth_mode',
          'context.exploration_summary_threshold',
        ]),
      );
      // Counted separately from the seven: the one field whose declaration was
      // stricter than its loader, and the agreeing declarations that prove the
      // sweep distinguished agreement from absence.
      expect(_reverseBoundDivergences, hasLength(1));
      expect(_agreeingBounds, hasLength(11));
      expect(_unenforcedStringDeclarations, hasLength(4));
      expect(_inexpressibleDeclarations, hasLength(5));

      for (final section in _registryDispositions) {
        section.forEach(_expectDeclarationMatchesDisposition);
      }
    });

    test('a string-typed field carrying an allowed set is one the table has ruled on', () {
      // `FieldConstraints` keys membership on `ConfigFieldType.enum_`, so an
      // allowed set declared over a `string` type is one the write path does
      // not apply. This is the one class of *new* divergence the registry can
      // detect unaided - a fifth such field, or the removal of one of these,
      // fails here. A parse-site bound added with no declaration at all is
      // caught by maintaining the table, not by this gate.
      expect(
        ConfigMeta.fields.values
            .where((field) => field.allowedValues != null && field.type != ConfigFieldType.enum_)
            .map((field) => field.yamlPath),
        unorderedEquals(_pathsRuled(_Disposition.declaredNotEnforcedOnWrite)),
      );
    });

    test('numeric loader bounds are derived or carry an explicit residual ruling', () async {
      expect(
        _numericBoundResiduals.keys,
        unorderedEquals(const [
          'tasks.budget.warning_threshold',
          'tasks.budget.default_max_tokens',
          'providers.<id>.pool_size',
          'mcp_servers.<name>.<section>.<key>',
          'mcp_servers.<name>.url IPv4 octets',
          'governance.turn_limits duration and ordering checks',
          'agent.history.max_total_chars < max_message_chars',
        ]),
      );

      final expectedLiteralSites = _numericBoundResiduals.values.expand((row) => row.literalSites).toSet();
      final actualLiteralSites = await _numericLiteralBoundSites();
      expect(
        actualLiteralSites,
        unorderedEquals(expectedLiteralSites),
        reason:
            'numeric bound literals without a declared residual ruling: '
            '${actualLiteralSites.difference(expectedLiteralSites)}',
      );
    });

    test('numeric residual scan catches multiline and FieldMeta fallback bounds', () {
      final sites = _numericLiteralBoundSitesInSource('synthetic.dart', '''
final clamped = value.clamp(
0, 100); final fallback = field.min ??
0; if (value <
0);
''');

      expect(sites.where((site) => site.contains('value.clamp( 0, 100')), isNotEmpty);
      expect(sites.where((site) => site.contains('field.min ?? 0')), isNotEmpty);
      expect(sites.where((site) => site.contains('value <')), isNotEmpty);
    });

    _registerConfigMembershipDispositionTests();

    test('the advisor surface is gone from the registry and from the package, not duplicated', () async {
      expect(ConfigMeta.fields.keys.where((path) => path.startsWith('advisor.')), isEmpty);

      final offenders = Directory(p.join(await _packageLibDir(), 'src'))
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where((file) => file.readAsStringSync().contains('_validAdvisorTriggers'))
          .map((file) => p.basename(file.path))
          .toList();
      expect(offenders, isEmpty, reason: 'the advisor trigger literal is back: $offenders');
    });
  });
}

/// Closed vocabulary for each loader-versus-registry disposition below.
enum _Disposition {
  declaredMax,

  maxDropped,

  declaredNotEnforcedOnWrite,

  derivedMembership,

  loaderMembershipResidual,

  /// No `FieldMeta` shape can carry the constraint, so the parse site keeps
  /// its own check and nothing derives from the declaration.
  inexpressible,

  /// Field and parse-site bound were both removed. The row survives so the
  /// removal cannot silently reverse into an undeclared bound.
  retired,

  /// Declaration and parse site already agreed. The control set is what proves
  /// the sweep distinguished agreement from absence.
  agrees,

  /// As [agrees], on a fractional field: the bound is integral at both ends but
  /// the value between them is not, so the declaration is `double_`.
  agreesFraction,
}

typedef _DispositionRow = ({
  _Disposition disposition,
  int? min,
  int? max,
  List<String>? allowedValues,
  String consequence,
});

/// Registry declarations whose bound the loader also decides, and the ruling
/// applied to each.
///
/// The registry is the schema every consumer reads - the write API, the
/// settings UI and the published schema - so a declaration that does not state
/// the bound the runtime applies advertises a range the runtime overrides. The
/// sections below are the complete set of places that was true, each with the
/// ruling and what it costs. A parse-site bound introduced with no declaration
/// at all is caught by maintaining this table, not by CI: the registry cannot
/// see a literal that was never declared.
final _registryDispositions = <Map<String, _DispositionRow>>[
  _boundDivergences,
  _reverseBoundDivergences,
  _agreeingBounds,
  _unenforcedStringDeclarations,
  _inexpressibleDeclarations,
  _derivedMembershipDeclarations,
  _membershipResiduals,
];

/// The paths swept for a loader-versus-registry bound divergence: each was
/// looser than the bound its parse site enforced, or has since lost both.
const _boundDivergences = <String, _DispositionRow>{
  'knowledge.inbox.interval_minutes': (
    disposition: _Disposition.declaredMax,
    min: 1,
    max: 1440,
    allowedValues: null,
    consequence:
        'A write above 1440 returned success, reached dartclaw.yaml and set restart.pending for a value the '
        'clamp discarded at that very restart; it is refused now. Load-side saturation is derived from the '
        'declaration, so an existing file still loads at 1440.',
  ),
  'knowledge.inbox.max_bytes': (
    disposition: _Disposition.declaredMax,
    min: 1,
    max: 52428800,
    allowedValues: null,
    consequence: 'Same silent-discard defect as the interval; the 50 MiB read bound stays enforced at load.',
  ),
  'knowledge.inbox.retry_attempts': (
    disposition: _Disposition.declaredMax,
    min: 0,
    max: 10,
    allowedValues: null,
    consequence: 'Same silent-discard defect; the clamp to 10 stays enforced at load.',
  ),
  'knowledge.inbox.processed_retention_days': (
    disposition: _Disposition.declaredMax,
    min: 0,
    max: 3650,
    allowedValues: null,
    consequence: 'Same silent-discard defect; the clamp to 3650 stays enforced at load.',
  ),
  'knowledge.wiki_lint.interval_minutes': (
    disposition: _Disposition.declaredMax,
    min: 1,
    max: 1440,
    allowedValues: null,
    consequence: 'Same silent-discard defect; the clamp to 1440 stays enforced at load.',
  ),
  'gateway.auth_mode': (
    disposition: _Disposition.derivedMembership,
    min: null,
    max: null,
    allowedValues: ['token', 'none'],
    consequence: 'Readonly at write; load membership now derives from the two-value declaration.',
  ),
  'context.exploration_summary_threshold': (
    disposition: _Disposition.retired,
    min: null,
    max: null,
    allowedValues: null,
    consequence:
        'The summarizer and its clamp(1000, 1000000) were deleted with the context re-cut; the key is ignored '
        'at load and answers nothing. The row stays so a re-registration without the declared bound is caught.',
  ),
};

/// The one declaration that was stricter than its parse site.
const _reverseBoundDivergences = <String, _DispositionRow>{
  'channels.google_chat.pubsub.poll_interval_seconds': (
    disposition: _Disposition.maxDropped,
    min: 1,
    max: null,
    allowedValues: null,
    consequence:
        'PubSubConfig enforces only >= 1 and never an upper bound, so the declared max refused a write the '
        'loader would have honoured. Dropping it loosens the write API onto behaviour the loader already had, '
        'and stops a later derivation of that site introducing a clamp at 60 no operator has today.',
  ),
};

/// Declarations that already reproduced their parse site's bound.
const _agreeingBounds = <String, _DispositionRow>{
  'tasks.budget.warning_threshold': (
    disposition: _Disposition.agreesFraction,
    min: 0,
    max: 1,
    allowedValues: null,
    consequence:
        'Registered late: the loader honoured a live key the registry never described, so the load sweep would '
        'have refused a booting config. The declaration reproduces the parse site\'s 0..1 range, and the fraction '
        'between the bounds is why it is double_ and not int_. One divergence stays: the parse site also accepts a '
        'numeric String, which FieldConstraints refuses, so \'0.8\' loads and takes effect but cannot be written '
        'back through the config API. Declaring string would lose the range instead, which is the worse trade.',
  ),
  'context.warning_threshold': (
    disposition: _Disposition.agrees,
    min: 50,
    max: 99,
    allowedValues: null,
    consequence:
        'The loader derives 50..99 from the declaration. This is the only live-tier row, and a hot reload runs the '
        'ConfigChangedEvent handler in dartclaw_runtime, which still clamps to 50, 99 of its own.',
  ),
  'tasks.artifact_retention_days': (
    disposition: _Disposition.agrees,
    min: 0,
    max: 3650,
    allowedValues: null,
    consequence: 'Load-side saturation derives 0..3650 from the declaration.',
  ),
  'tasks.worktree.stale_timeout_hours': (
    disposition: _Disposition.agrees,
    min: 1,
    max: 168,
    allowedValues: null,
    consequence: 'Load-side saturation derives 1..168 from the declaration.',
  ),
  'guard_audit.max_retention_days': (
    disposition: _Disposition.agrees,
    min: 0,
    max: 365,
    allowedValues: null,
    consequence: 'Load-side saturation derives 0..365 from the declaration.',
  ),
  'gateway.reload.debounce_ms': (
    disposition: _Disposition.agrees,
    min: 100,
    max: null,
    allowedValues: null,
    consequence: 'Lower bound matches the loader; no upper bound is enforced anywhere.',
  ),
  'alerts.cooldown_seconds': (
    disposition: _Disposition.agrees,
    min: 1,
    max: null,
    allowedValues: null,
    consequence: 'Lower bound matches the loader; no upper bound is enforced anywhere.',
  ),
  'alerts.burst_threshold': (
    disposition: _Disposition.agrees,
    min: 1,
    max: null,
    allowedValues: null,
    consequence: 'Lower bound matches the loader; no upper bound is enforced anywhere.',
  ),
  'onboarding.expiry_days': (
    disposition: _Disposition.agrees,
    min: 1,
    max: null,
    allowedValues: null,
    consequence: 'Lower bound matches the loader; no upper bound is enforced anywhere.',
  ),
  'channels.google_chat.pubsub.max_messages_per_pull': (
    disposition: _Disposition.agrees,
    min: 1,
    max: 100,
    allowedValues: null,
    consequence:
        'Out-of-package, and the one bound whose loader warns on both ends rather than clamping silently; '
        '1-100 already matches it.',
  ),
  'channels.signal.port': (
    disposition: _Disposition.agrees,
    min: 1,
    max: 65535,
    allowedValues: null,
    consequence: 'The Signal loader derives its accepted port range and its advisory bounds from the declaration.',
  ),
};

/// The five allowed-set declarations handed over as unenforced on the write
/// path, each with the ruling applied to it.
///
/// The write path compares exactly. Four of these parse sites trim first, so
/// making them `enum_` would start refusing a trailing-whitespace value that
/// works end to end today - a regression, and the reason they stay declared
/// rather than enforced. Their loaders retain the trimming membership check;
/// the disposition and mapper-spelling gates keep that residual explicit.
const _unenforcedStringDeclarations = <String, _DispositionRow>{
  'workflow.approvals': (
    disposition: _Disposition.declaredNotEnforcedOnWrite,
    min: null,
    max: null,
    allowedValues: ['manual', 'auto-on-stall', 'auto'],
    consequence:
        "WorkflowApprovalPolicy.fromYaml trims, so 'auto ' works today and must keep working. Residual: a "
        'non-member write is still accepted, persisted, and warned-and-defaulted at the next boot.',
  ),
  'tasks.completion_action': (
    disposition: _Disposition.declaredNotEnforcedOnWrite,
    min: null,
    max: null,
    allowedValues: ['review', 'accept'],
    consequence: "The parse site trims, so 'accept ' works today. Same residual as workflow.approvals.",
  ),
  'knowledge.inbox.delivery_mode': (
    disposition: _Disposition.declaredNotEnforcedOnWrite,
    min: null,
    max: null,
    allowedValues: ['none', 'announce', 'webhook'],
    consequence: "_knowledgeDeliveryMode trims, so 'announce ' works today. Same residual.",
  ),
  'knowledge.wiki_lint.delivery_mode': (
    disposition: _Disposition.declaredNotEnforcedOnWrite,
    min: null,
    max: null,
    allowedValues: ['none', 'announce', 'webhook'],
    consequence: "_knowledgeDeliveryMode trims, so 'announce ' works today. Same residual.",
  ),
};

/// Checks no `FieldMeta` shape can carry, so their parse sites keep their own
/// and nothing is derived from the declaration - plus the retired advisor row,
/// whose element-level values were inexpressible before the surface was deleted.
///
/// The same class exists out of package on `channels.google_chat.feedback.
/// min_feedback_delay` and `channels.google_chat.feedback.status_interval`,
/// which run the same `tryParseDuration` over a `string` declaration.
const _inexpressibleDeclarations = <String, _DispositionRow>{
  'governance.turn_limits.stall_timeout': (
    disposition: _Disposition.inexpressible,
    min: 0,
    max: null,
    allowedValues: null,
    consequence:
        'Integer seconds carry their non-negative bound; no duration type or string pattern can declare the same '
        'bound for duration strings, so the parse site keeps its tryParseDuration check.',
  ),
  'governance.turn_limits.turn_timeout': (
    disposition: _Disposition.inexpressible,
    min: 0,
    max: null,
    allowedValues: null,
    consequence:
        'Integer seconds carry their non-negative bound; no duration type or string pattern can declare the same '
        'bound for duration strings, so the parse site keeps its tryParseDuration check.',
  ),
  'channels.google_chat.feedback.min_feedback_delay': (
    disposition: _Disposition.inexpressible,
    min: null,
    max: null,
    allowedValues: null,
    consequence: 'No duration type and no string pattern to declare; the parse site keeps its tryParseDuration check.',
  ),
  'channels.google_chat.feedback.status_interval': (
    disposition: _Disposition.inexpressible,
    min: null,
    max: null,
    allowedValues: null,
    consequence: 'No duration type and no string pattern to declare; the parse site keeps its tryParseDuration check.',
  ),
  'advisor.triggers': (
    disposition: _Disposition.retired,
    min: null,
    max: null,
    allowedValues: null,
    consequence:
        'The advisor surface and both copies of its trigger literal are gone. A stringList had no element-level '
        'allowedValues to derive from either way, and growing the declaration shape is not this reconciliation.',
  ),
};

typedef _NumericBoundResidual = ({String reason, List<String> literalSites});

const _numericBoundResiduals = <String, _NumericBoundResidual>{
  'tasks.budget.warning_threshold': (
    reason: 'The loader accepts numeric strings and fractional values; the shared integer-bound clamp shape cannot preserve it.',
    literalSites: ['config_parser.dart|if (parsed != null && parsed >= 0.0 && parsed <= 1.0) {'],
  ),
  'tasks.budget.default_max_tokens': (
    reason: 'Values at or below zero are the documented unbudgeted sentinel, not an invalid range.',
    literalSites: ['config_parser.dart|defaultMaxTokens: defaultMaxTokens > 0 ? defaultMaxTokens : null,'],
  ),
  'providers.<id>.pool_size': (
    reason: 'The bound belongs to an object-map entry shape, not a resolvable FieldMeta.',
    literalSites: ['config_parser_providers.dart|if (poolSize < 0) {'],
  ),
  'mcp_servers.<name>.<section>.<key>': (
    reason: 'The four non-negative integers belong to object-map entry shapes, not resolvable FieldMeta values.',
    literalSites: ['config_parser_providers.dart|if (raw < 0) {'],
  ),
  'mcp_servers.<name>.url IPv4 octets': (
    reason: 'The 0..255 range validates segments inside a URL string and is not a numeric config field.',
    literalSites: [
      'config_parser_providers.dart|return value != null && value >= 0 && value <= 255 && value.toString() == octet;',
    ],
  ),
  'governance.turn_limits duration and ordering checks': (
    reason: 'Duration positivity and cross-field ordering are not expressible by FieldMeta integer bounds.',
    literalSites: [],
  ),
  'agent.history.max_total_chars < max_message_chars': (
    reason: 'The total-versus-message ordering rule is conditional across two fields.',
    literalSites: [],
  ),
};

Future<Set<String>> _numericLiteralBoundSites() async {
  final sourceDir = Directory(p.join(await _packageLibDir(), 'src'));
  final files = sourceDir.listSync().whereType<File>().where((file) {
    final name = p.basename(file.path);
    return name == 'workflow_config.dart' || name == 'config_numeric_bounds.dart' || name.startsWith('config_parser');
  }).toList();
  final sites = <String>{};

  for (final file in files) {
    sites.addAll(_numericLiteralBoundSitesInSource(p.basename(file.path), file.readAsStringSync()));
  }
  return sites;
}

Set<String> _numericLiteralBoundSitesInSource(String fileName, String source) {
  final masked = _maskNonCode(source);
  final patterns = [
    RegExp(r'\.clamp\s*\([^)]*?-?\d+(?:\.\d+)?', dotAll: true),
    RegExp(r'(?:<=|>=|<|>)\s*-?\d+(?:\.\d+)?', dotAll: true),
    RegExp(r'\b(?:min|max)\s*\?\?\s*-?\d+(?:\.\d+)?', dotAll: true),
  ];
  final sites = <String>{};
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(masked)) {
      final start = source.lastIndexOf('\n', match.start) + 1;
      final end = source.indexOf('\n', match.end);
      final line = source.substring(start, end == -1 ? source.length : end).replaceAll(RegExp(r'\s+'), ' ').trim();
      sites.add('$fileName|$line');
    }
  }
  return sites;
}

String _maskNonCode(String source) {
  final token = RegExp(r'''(?:'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/)''');
  return source.replaceAllMapped(token, (match) {
    final text = match.group(0)!;
    return text.replaceAll(RegExp(r'[^\n]'), ' ');
  });
}

/// Absolute path of this package's `lib/`, resolved through the package config
/// so the test does not depend on the working directory.
Future<String> _packageLibDir() async {
  final libUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_kernel/dartclaw_kernel.dart'));
  return p.dirname(libUri!.toFilePath());
}

/// Words a description contributes beyond a restatement of its own key.
Set<String> _informativeWords(String description, String yamlPath) {
  const filler = {
    'a',
    'an',
    'the',
    'and',
    'or',
    'of',
    'to',
    'for',
    'in',
    'on',
    'is',
    'it',
    'its',
    'be',
    'as',
    'at',
    'by',
    'with',
    'this',
    'that',
    'when',
    'while',
    'whether',
    'which',
    'how',
    'what',
    'per',
    'use',
    'used',
    'uses',
    'set',
    'sets',
    'value',
    'values',
    'default',
    'defaults',
    'config',
    'configured',
    'configuration',
    'option',
    'setting',
    'settings',
  };
  final pathWords = yamlPath.toLowerCase().split(RegExp('[^a-z0-9]+')).where((word) => word.isNotEmpty).toSet();
  return description
      .toLowerCase()
      .split(RegExp('[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toSet()
      .difference(pathWords)
      .difference(filler);
}

Map<String, EntryFieldMeta> _entryFieldsOf(ConfigEntryShape? shape) => switch (shape) {
  ObjectEntry(:final fields) => {
    ...fields,
    for (final field in fields.entries)
      ..._entryFieldsOf(field.value.entry).map((k, v) => MapEntry('${field.key}.$k', v)),
  },
  ValueEntry(:final value) => {'': value},
  OpaqueEntry() || null => const {},
};

/// Whether [leaf] is answerable: an exact registration, or an enclosing
/// object-valued field whose entry shape actually **names** it (longest match
/// wins).
///
/// The shape has to declare the remaining segments. A shape that merely exists
/// would make every descendant of an object-valued field resolve, which is how
/// a coverage gate silently stops catching anything.
bool _resolves(String leaf) {
  if (ConfigMeta.isKnown(leaf)) return true;
  final segments = leaf.split('.');
  for (var length = segments.length - 1; length > 0; length--) {
    final meta = ConfigMeta.fields[segments.take(length).join('.')];
    if (meta == null) continue;
    final shape = meta.entry;
    if (shape == null) return false;
    // An objectMap is keyed by an operator-chosen name, so that segment is the
    // entry key rather than part of the entry's own shape.
    final relative = meta.type == ConfigFieldType.objectMap
        ? segments.skip(length + 1).join('.')
        : segments.skip(length).join('.');
    return switch (shape) {
      // An opaque shape names no field, so it answers for the entry itself and
      // for no descendant — otherwise one open container would make every path
      // beneath it resolve, which is how a coverage gate stops catching.
      OpaqueEntry() => relative.isEmpty,
      ValueEntry() => relative.isEmpty,
      ObjectEntry() => relative.isEmpty || _entryFieldsOf(shape).containsKey(relative),
    };
  }
  return false;
}

Future<String> _guideSource() => _repoFile(p.join('docs', 'guide', 'configuration.md'));

Future<String> _repoFile(String relativePath) async {
  final libDir = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_kernel/dartclaw_kernel.dart'));
  final repoRoot = p.normalize(p.join(p.dirname(libDir!.toFilePath()), '..', '..', '..'));
  return File(p.join(repoRoot, relativePath)).readAsStringSync();
}

/// The `### Deprecated` block under the changelog's `## [Unreleased]` heading.
///
/// Bounded to that release's own block: searching on to end-of-file would let a
/// released `### Deprecated` section answer for the unreleased one the moment
/// release prep renames the heading, and the gate would pass on a row nobody
/// announced.
String _unreleasedDeprecatedSection(String markdown) {
  final lines = markdown.split('\n');
  final unreleased = lines.indexWhere((line) => line.trim() == '## [Unreleased]');
  if (unreleased < 0) return '';
  final nextRelease = lines.indexWhere((line) => line.startsWith('## '), unreleased + 1);
  final block = lines.sublist(unreleased + 1, nextRelease < 0 ? lines.length : nextRelease);

  final start = block.indexWhere((line) => line.trim() == '### Deprecated');
  if (start < 0) return '';
  final end = block.indexWhere((line) => line.startsWith('#'), start + 1);
  return block.sublist(start + 1, end < 0 ? block.length : end).join('\n');
}

/// Leaf paths documented in the guide's generated Full Config Reference table.
Set<String> _guideConfigLeaves(String markdown) {
  final lines = markdown.split('\n');
  final start = lines.indexWhere((line) => line.trim() == '### Full Config Reference');
  if (start < 0) return const {};
  final end = lines.indexWhere((line) => line.trim() == '<!-- END GENERATED CONFIG REFERENCE -->', start);
  if (end < 0) return const {};
  final leaves = <String>{};
  final rowPattern = RegExp(r'^\| `([^`]+)` \|');
  for (final line in lines.sublist(start + 1, end)) {
    final match = rowPattern.firstMatch(line);
    if (match != null) leaves.add(match.group(1)!);
  }
  return leaves;
}
