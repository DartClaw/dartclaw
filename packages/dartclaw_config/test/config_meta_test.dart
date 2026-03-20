import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('ConfigMeta', () {
    group('registry completeness', () {
      test('fields map is non-empty', () {
        expect(ConfigMeta.fields, isNotEmpty);
      });

      test('every field has non-empty yamlPath and jsonKey', () {
        for (final entry in ConfigMeta.fields.entries) {
          expect(entry.value.yamlPath, isNotEmpty, reason: 'yamlPath empty for ${entry.key}');
          expect(entry.value.jsonKey, isNotEmpty, reason: 'jsonKey empty for ${entry.key}');
        }
      });

      test('map keys match yamlPath values', () {
        for (final entry in ConfigMeta.fields.entries) {
          expect(entry.key, equals(entry.value.yamlPath), reason: 'key mismatch for ${entry.key}');
        }
      });

      test('all spec fields are registered', () {
        // Live fields
        expect(ConfigMeta.fields, contains('scheduling.heartbeat.enabled'));
        expect(ConfigMeta.fields, contains('workspace.git_sync.enabled'));
        expect(ConfigMeta.fields, contains('workspace.git_sync.push_enabled'));

        // Restart fields
        expect(ConfigMeta.fields, contains('port'));
        expect(ConfigMeta.fields, contains('host'));
        expect(ConfigMeta.fields, contains('data_dir'));
        expect(ConfigMeta.fields, contains('worker_timeout'));
        // memory_max_bytes was removed — top-level field no longer registered
        expect(ConfigMeta.fields, isNot(contains('memory_max_bytes')));
        expect(ConfigMeta.fields, contains('agent.model'));
        expect(ConfigMeta.fields, contains('agent.max_turns'));
        expect(ConfigMeta.fields, contains('agent.effort'));
        expect(ConfigMeta.fields, contains('auth.cookie_secure'));
        expect(ConfigMeta.fields, contains('auth.trusted_proxies'));
        expect(ConfigMeta.fields, contains('tasks.max_concurrent'));
        expect(ConfigMeta.fields, contains('tasks.artifact_retention_days'));
        expect(ConfigMeta.fields, contains('tasks.worktree.base_ref'));
        expect(ConfigMeta.fields, contains('tasks.worktree.stale_timeout_hours'));
        expect(ConfigMeta.fields, contains('tasks.worktree.merge_strategy'));
        expect(ConfigMeta.fields, contains('concurrency.max_parallel_turns'));
        expect(ConfigMeta.fields, contains('guard_audit.max_retention_days'));
        expect(ConfigMeta.fields, contains('sessions.reset_hour'));
        expect(ConfigMeta.fields, contains('sessions.idle_timeout_minutes'));
        expect(ConfigMeta.fields, contains('logging.level'));
        expect(ConfigMeta.fields, contains('logging.format'));
        expect(ConfigMeta.fields, contains('scheduling.heartbeat.interval_minutes'));
        expect(ConfigMeta.fields, contains('context.reserve_tokens'));
        expect(ConfigMeta.fields, contains('context.max_result_bytes'));
        expect(ConfigMeta.fields, contains('context.warning_threshold'));
        expect(ConfigMeta.fields, contains('context.exploration_summary_threshold'));
        expect(ConfigMeta.fields, contains('context.compact_instructions'));
        expect(ConfigMeta.fields, contains('search.backend'));
        expect(ConfigMeta.fields, contains('search.qmd.host'));
        expect(ConfigMeta.fields, contains('search.qmd.port'));
        expect(ConfigMeta.fields, contains('search.default_depth'));
        expect(ConfigMeta.fields, contains('logging.file'));
        expect(ConfigMeta.fields, contains('logging.redact_patterns'));
        expect(ConfigMeta.fields, contains('guards.content.enabled'));
        expect(ConfigMeta.fields, contains('guards.content.classifier'));
        expect(ConfigMeta.fields, contains('guards.content.model'));
        expect(ConfigMeta.fields, contains('guards.content.max_bytes'));
        expect(ConfigMeta.fields, contains('guards.input_sanitizer.enabled'));
        expect(ConfigMeta.fields, contains('guards.input_sanitizer.channels_only'));
        expect(ConfigMeta.fields, contains('memory.pruning.enabled'));
        expect(ConfigMeta.fields, contains('memory.pruning.archive_after_days'));
        expect(ConfigMeta.fields, contains('memory.pruning.schedule'));
        expect(ConfigMeta.fields, contains('usage.budget_warning_tokens'));
        expect(ConfigMeta.fields, contains('usage.max_file_size_bytes'));
        expect(ConfigMeta.fields, contains('channels.google_chat.enabled'));
        expect(ConfigMeta.fields, contains('channels.google_chat.service_account'));
        expect(ConfigMeta.fields, contains('channels.google_chat.audience.type'));
        expect(ConfigMeta.fields, contains('channels.google_chat.audience.value'));
        expect(ConfigMeta.fields, contains('channels.google_chat.webhook_path'));
        expect(ConfigMeta.fields, contains('channels.google_chat.bot_user'));
        expect(ConfigMeta.fields, contains('channels.google_chat.typing_indicator'));
        expect(ConfigMeta.fields, contains('channels.google_chat.dm_access'));
        expect(ConfigMeta.fields, contains('channels.google_chat.dm_allowlist'));
        expect(ConfigMeta.fields, contains('channels.google_chat.group_access'));
        expect(ConfigMeta.fields, contains('channels.google_chat.group_allowlist'));
        expect(ConfigMeta.fields, contains('channels.google_chat.require_mention'));
        expect(ConfigMeta.fields, contains('channels.whatsapp.task_trigger.enabled'));
        expect(ConfigMeta.fields, contains('channels.whatsapp.task_trigger.prefix'));
        expect(ConfigMeta.fields, contains('channels.whatsapp.task_trigger.default_type'));
        expect(ConfigMeta.fields, contains('channels.whatsapp.task_trigger.auto_start'));
        expect(ConfigMeta.fields, contains('channels.signal.task_trigger.enabled'));
        expect(ConfigMeta.fields, contains('channels.signal.task_trigger.prefix'));
        expect(ConfigMeta.fields, contains('channels.signal.task_trigger.default_type'));
        expect(ConfigMeta.fields, contains('channels.signal.task_trigger.auto_start'));
        expect(ConfigMeta.fields, contains('channels.google_chat.task_trigger.enabled'));
        expect(ConfigMeta.fields, contains('channels.google_chat.task_trigger.prefix'));
        expect(ConfigMeta.fields, contains('channels.google_chat.task_trigger.default_type'));
        expect(ConfigMeta.fields, contains('channels.google_chat.task_trigger.auto_start'));

        // Readonly fields
        expect(ConfigMeta.fields, contains('gateway.auth_mode'));
        expect(ConfigMeta.fields, contains('gateway.token'));
        expect(ConfigMeta.fields, contains('gateway.hsts'));
      });
    });

    group('mutability classification', () {
      test('classifies live fields correctly', () {
        expect(ConfigMeta.fields['scheduling.heartbeat.enabled']!.mutability, ConfigMutability.live);
        expect(ConfigMeta.fields['workspace.git_sync.enabled']!.mutability, ConfigMutability.live);
        expect(ConfigMeta.fields['workspace.git_sync.push_enabled']!.mutability, ConfigMutability.live);
        expect(ConfigMeta.fields['sessions.dm_scope']!.mutability, ConfigMutability.live);
        expect(ConfigMeta.fields['sessions.group_scope']!.mutability, ConfigMutability.live);
      });

      test('classifies restart fields correctly', () {
        expect(ConfigMeta.fields['port']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['agent.model']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['auth.cookie_secure']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['auth.trusted_proxies']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['gateway.hsts']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['tasks.artifact_retention_days']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['guard_audit.max_retention_days']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['context.exploration_summary_threshold']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['context.compact_instructions']!.mutability, ConfigMutability.restart);
      });

      test('context.warning_threshold is live-mutable with range 50-99', () {
        final meta = ConfigMeta.fields['context.warning_threshold']!;
        expect(meta.mutability, ConfigMutability.live);
        expect(meta.type, ConfigFieldType.int_);
        expect(meta.min, 50);
        expect(meta.max, 99);
      });

      test('context.exploration_summary_threshold has min 1000', () {
        final meta = ConfigMeta.fields['context.exploration_summary_threshold']!;
        expect(meta.type, ConfigFieldType.int_);
        expect(meta.min, 1000);
      });

      test('context.compact_instructions is nullable string', () {
        final meta = ConfigMeta.fields['context.compact_instructions']!;
        expect(meta.type, ConfigFieldType.string);
        expect(meta.nullable, true);
      });

      test('classifies readonly fields correctly', () {
        expect(ConfigMeta.fields['gateway.auth_mode']!.mutability, ConfigMutability.readonly);
        expect(ConfigMeta.fields['gateway.token']!.mutability, ConfigMutability.readonly);
      });

      test('task trigger fields are restart', () {
        expect(ConfigMeta.fields['channels.whatsapp.task_trigger.enabled']!.mutability, ConfigMutability.restart);
        expect(ConfigMeta.fields['channels.signal.task_trigger.prefix']!.mutability, ConfigMutability.restart);
        expect(
          ConfigMeta.fields['channels.google_chat.task_trigger.default_type']!.mutability,
          ConfigMutability.restart,
        );
        expect(ConfigMeta.fields['channels.google_chat.task_trigger.auto_start']!.mutability, ConfigMutability.restart);
      });

      test('task trigger default_type uses string metadata to preserve custom values', () {
        expect(ConfigMeta.fields['channels.whatsapp.task_trigger.default_type']!.type, ConfigFieldType.string);
        expect(ConfigMeta.fields['channels.signal.task_trigger.default_type']!.type, ConfigFieldType.string);
        expect(ConfigMeta.fields['channels.google_chat.task_trigger.default_type']!.type, ConfigFieldType.string);
      });
    });

    group('JSON key mapping', () {
      test('byJsonKey contains all fields', () {
        expect(ConfigMeta.byJsonKey.length, equals(ConfigMeta.fields.length));
      });

      test('scheduling.heartbeat.interval_minutes maps correctly', () {
        expect(
          ConfigMeta.fields['scheduling.heartbeat.interval_minutes']!.jsonKey,
          equals('scheduling.heartbeat.intervalMinutes'),
        );
      });

      test('agent.max_turns maps to agent.maxTurns', () {
        expect(ConfigMeta.fields['agent.max_turns']!.jsonKey, equals('agent.maxTurns'));
      });

      test('concurrency.max_parallel_turns maps correctly', () {
        expect(ConfigMeta.fields['concurrency.max_parallel_turns']!.jsonKey, equals('concurrency.maxParallelTurns'));
      });

      test('new retention fields map correctly', () {
        expect(ConfigMeta.fields['guard_audit.max_retention_days']!.jsonKey, equals('guardAudit.maxRetentionDays'));
        expect(ConfigMeta.fields['tasks.artifact_retention_days']!.jsonKey, equals('tasks.artifactRetentionDays'));
      });

      test('byJsonKey lookup works', () {
        final meta = ConfigMeta.byJsonKey['scheduling.heartbeat.intervalMinutes'];
        expect(meta, isNotNull);
        expect(meta!.yamlPath, equals('scheduling.heartbeat.interval_minutes'));
      });
    });

    group('helpers', () {
      test('isKnown returns correct values', () {
        expect(ConfigMeta.isKnown('port'), isTrue);
        expect(ConfigMeta.isKnown('nonexistent'), isFalse);
      });

      test('isWritable returns correct values', () {
        expect(ConfigMeta.isWritable('port'), isTrue);
        expect(ConfigMeta.isWritable('scheduling.heartbeat.enabled'), isTrue);
        expect(ConfigMeta.isWritable('channels.whatsapp.task_trigger.enabled'), isTrue);
        expect(ConfigMeta.isWritable('channels.signal.task_trigger.prefix'), isTrue);
        expect(ConfigMeta.isWritable('channels.google_chat.task_trigger.default_type'), isTrue);
        expect(ConfigMeta.isWritable('gateway.auth_mode'), isFalse);
        expect(ConfigMeta.isWritable('nonexistent'), isFalse);
      });

      test('forMutability returns expected live fields', () {
        final live = ConfigMeta.forMutability(ConfigMutability.live).toList();
        expect(live, hasLength(6));
        final paths = live.map((f) => f.yamlPath).toSet();
        expect(
          paths,
          containsAll([
            'sessions.dm_scope',
            'sessions.group_scope',
            'scheduling.heartbeat.enabled',
            'workspace.git_sync.enabled',
            'workspace.git_sync.push_enabled',
            'context.warning_threshold',
          ]),
        );
      });

      test('forMutability readonly returns gateway and Google Chat credential fields', () {
        final ro = ConfigMeta.forMutability(ConfigMutability.readonly).toList();
        expect(ro, hasLength(5));
        final paths = ro.map((f) => f.yamlPath).toSet();
        expect(
          paths,
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
  });
}
