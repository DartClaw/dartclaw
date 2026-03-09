import 'package:dartclaw_server/dartclaw_server.dart';
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
        expect(ConfigMeta.fields, contains('memory_max_bytes'));
        expect(ConfigMeta.fields, contains('agent.model'));
        expect(ConfigMeta.fields, contains('agent.max_turns'));
        expect(ConfigMeta.fields, contains('agent.context_1m'));
        expect(ConfigMeta.fields, contains('concurrency.max_parallel_turns'));
        expect(ConfigMeta.fields, contains('sessions.reset_hour'));
        expect(ConfigMeta.fields, contains('sessions.idle_timeout_minutes'));
        expect(ConfigMeta.fields, contains('logging.level'));
        expect(ConfigMeta.fields, contains('logging.format'));
        expect(ConfigMeta.fields, contains('scheduling.heartbeat.interval_minutes'));
        expect(ConfigMeta.fields, contains('context.reserve_tokens'));
        expect(ConfigMeta.fields, contains('context.max_result_bytes'));
        expect(ConfigMeta.fields, contains('search.backend'));
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

        // Readonly fields
        expect(ConfigMeta.fields, contains('gateway.auth_mode'));
        expect(ConfigMeta.fields, contains('gateway.token'));
        expect(ConfigMeta.fields, contains('gateway.hsts'));
      });
    });

    group('mutability classification', () {
      test('scheduling.heartbeat.enabled is live', () {
        expect(ConfigMeta.fields['scheduling.heartbeat.enabled']!.mutability, ConfigMutability.live);
      });

      test('workspace.git_sync.enabled is live', () {
        expect(ConfigMeta.fields['workspace.git_sync.enabled']!.mutability, ConfigMutability.live);
      });

      test('workspace.git_sync.push_enabled is live', () {
        expect(ConfigMeta.fields['workspace.git_sync.push_enabled']!.mutability, ConfigMutability.live);
      });

      test('port is restart', () {
        expect(ConfigMeta.fields['port']!.mutability, ConfigMutability.restart);
      });

      test('agent.model is restart', () {
        expect(ConfigMeta.fields['agent.model']!.mutability, ConfigMutability.restart);
      });

      test('gateway.auth_mode is readonly', () {
        expect(ConfigMeta.fields['gateway.auth_mode']!.mutability, ConfigMutability.readonly);
      });

      test('gateway.token is readonly', () {
        expect(ConfigMeta.fields['gateway.token']!.mutability, ConfigMutability.readonly);
      });

      test('gateway.hsts is restart', () {
        expect(ConfigMeta.fields['gateway.hsts']!.mutability, ConfigMutability.restart);
      });

      test('sessions scope fields are live', () {
        expect(ConfigMeta.fields['sessions.dm_scope']!.mutability, ConfigMutability.live);
        expect(ConfigMeta.fields['sessions.group_scope']!.mutability, ConfigMutability.live);
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

      test('byJsonKey lookup works', () {
        final meta = ConfigMeta.byJsonKey['scheduling.heartbeat.intervalMinutes'];
        expect(meta, isNotNull);
        expect(meta!.yamlPath, equals('scheduling.heartbeat.interval_minutes'));
      });
    });

    group('helpers', () {
      test('isKnown returns true for registered field', () {
        expect(ConfigMeta.isKnown('port'), isTrue);
      });

      test('isKnown returns false for unregistered field', () {
        expect(ConfigMeta.isKnown('nonexistent'), isFalse);
      });

      test('isWritable returns true for restart field', () {
        expect(ConfigMeta.isWritable('port'), isTrue);
      });

      test('isWritable returns true for live field', () {
        expect(ConfigMeta.isWritable('scheduling.heartbeat.enabled'), isTrue);
      });

      test('isWritable returns false for readonly field', () {
        expect(ConfigMeta.isWritable('gateway.auth_mode'), isFalse);
      });

      test('isWritable returns false for unknown field', () {
        expect(ConfigMeta.isWritable('nonexistent'), isFalse);
      });

      test('forMutability returns expected live fields', () {
        final live = ConfigMeta.forMutability(ConfigMutability.live).toList();
        expect(live, hasLength(5));
        final paths = live.map((f) => f.yamlPath).toSet();
        expect(
          paths,
          containsAll([
            'sessions.dm_scope',
            'sessions.group_scope',
            'scheduling.heartbeat.enabled',
            'workspace.git_sync.enabled',
            'workspace.git_sync.push_enabled',
          ]),
        );
      });

      test('forMutability readonly returns gateway fields', () {
        final ro = ConfigMeta.forMutability(ConfigMutability.readonly).toList();
        expect(ro, hasLength(2));
        final paths = ro.map((f) => f.yamlPath).toSet();
        expect(paths, containsAll(['gateway.auth_mode', 'gateway.token']));
      });
    });
  });
}
