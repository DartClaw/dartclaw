import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  const validator = ConfigValidator();

  group('ConfigValidator', () {
    test('accepts valid primitive and enum field updates', () {
      final cases = <Map<String, dynamic>>[
        {'port': 3000},
        {'port': 3000.0},
        {'concurrency.max_parallel_turns': 5},
        {'sessions.reset_hour': 12},
        {'sessions.idle_timeout_minutes': 0},
        {'agent.max_turns': null},
        {'agent.max_turns': 5},
        {'usage.budget_warning_tokens': null},
        {'usage.budget_warning_tokens': 1000},
        {'host': 'localhost'},
        {'agent.model': 'sonnet'},
        {'agent.model': null},
        {'channels.whatsapp.task_trigger.prefix': 'task:'},
        {'scheduling.heartbeat.enabled': true},
        {'scheduling.heartbeat.enabled': false},
        {'channels.google_chat.task_trigger.default_type': 'analysis'},
        {'channels.google_chat.task_trigger.default_type': 'future_type'},
        {'sessions.dm_scope': 'per-contact'},
        {'sessions.dm_scope': 'shared'},
        {'sessions.dm_scope': 'per-channel-contact'},
        {'sessions.group_scope': 'shared'},
        {'sessions.group_scope': 'per-member'},
        {'logging.level': 'INFO'},
        {'logging.format': 'human'},
        {'search.backend': 'fts5'},
        {'guards.content.classifier': 'claude_binary'},
        {'context.warning_threshold': 80},
        {'context.warning_threshold': 50},
        {'context.warning_threshold': 99},
        {'context.exploration_summary_threshold': 25000},
        {'context.exploration_summary_threshold': 1000},
        {'context.compact_instructions': 'Preserve key findings'},
        {'context.compact_instructions': null},
        {'sessions.maintenance.mode': 'warn'},
        {'sessions.maintenance.mode': 'enforce'},
        {
          'sessions.maintenance.prune_after_days': 30,
          'sessions.maintenance.max_sessions': 500,
          'sessions.maintenance.max_disk_mb': 1024,
          'sessions.maintenance.cron_retention_hours': 24,
          'sessions.maintenance.schedule': '0 4 * * *',
        },
        {
          'channels.google_chat.dm_allowlist': ['spaces/AAA/users/1'],
        },
      ];

      for (final updates in cases) {
        expect(validator.validate(updates), isEmpty, reason: updates.toString());
      }
    });

    test('rejects invalid primitive, enum, and unknown field updates', () {
      final cases = <({Map<String, dynamic> updates, String field, List<String> messageContains})>[
        (updates: {'port': 0}, field: 'port', messageContains: ['between 1 and 65535']),
        (updates: {'port': 65536}, field: 'port', messageContains: ['between 1 and 65535']),
        (updates: {'port': 'abc'}, field: 'port', messageContains: ['must be an integer', 'String']),
        (updates: {'port': -1}, field: 'port', messageContains: ['between 1 and 65535']),
        (updates: {'worker_timeout': 0}, field: 'worker_timeout', messageContains: ['>= 1']),
        (updates: {'sessions.reset_hour': 24}, field: 'sessions.reset_hour', messageContains: ['between 0 and 23']),
        (updates: {'sessions.reset_hour': -1}, field: 'sessions.reset_hour', messageContains: ['between 0 and 23']),
        (
          updates: {'concurrency.max_parallel_turns': 0},
          field: 'concurrency.max_parallel_turns',
          messageContains: ['between 1 and 10'],
        ),
        (
          updates: {'concurrency.max_parallel_turns': 11},
          field: 'concurrency.max_parallel_turns',
          messageContains: ['between 1 and 10'],
        ),
        (updates: {'agent.max_turns': 0}, field: 'agent.max_turns', messageContains: ['>= 1']),
        (updates: {'host': ''}, field: 'host', messageContains: ['must not be empty']),
        (updates: {'host': '  '}, field: 'host', messageContains: ['must not be empty']),
        (updates: {'host': 123}, field: 'host', messageContains: ['must be a string', 'int']),
        (updates: {'data_dir': ''}, field: 'data_dir', messageContains: ['must not be empty']),
        (
          updates: {'channels.whatsapp.task_trigger.prefix': '   '},
          field: 'channels.whatsapp.task_trigger.prefix',
          messageContains: ['must not be empty'],
        ),
        (
          updates: {'scheduling.heartbeat.enabled': 'true'},
          field: 'scheduling.heartbeat.enabled',
          messageContains: ['must be a boolean', 'String'],
        ),
        (
          updates: {'channels.google_chat.task_trigger.default_type': '   '},
          field: 'channels.google_chat.task_trigger.default_type',
          messageContains: ['must not be empty'],
        ),
        (updates: {'sessions.dm_scope': 'invalid'}, field: 'sessions.dm_scope', messageContains: ['must be one of']),
        (
          updates: {'sessions.group_scope': 'invalid'},
          field: 'sessions.group_scope',
          messageContains: ['must be one of'],
        ),
        (updates: {'sessions.dm_scope': 'perContact'}, field: 'sessions.dm_scope', messageContains: ['must be one of']),
        (updates: {'logging.level': 'DEBUG'}, field: 'logging.level', messageContains: ['must be one of', 'DEBUG']),
        (updates: {'logging.level': 'info'}, field: 'logging.level', messageContains: ['must be one of']),
        (updates: {'logging.format': 'xml'}, field: 'logging.format', messageContains: ['must be one of']),
        (updates: {'search.backend': 'elasticsearch'}, field: 'search.backend', messageContains: ['must be one of']),
        (
          updates: {'guards.content.classifier': 'openai'},
          field: 'guards.content.classifier',
          messageContains: ['must be one of'],
        ),
        (updates: {'gateway.auth_mode': 'none'}, field: 'gateway.auth_mode', messageContains: ['read-only']),
        (updates: {'gateway.token': 'secret'}, field: 'gateway.token', messageContains: ['read-only']),
        (updates: {'nonexistent': 42}, field: 'nonexistent', messageContains: ['Unknown config field']),
        (
          updates: {
            'agent.disallowed_tools': ['tool1'],
          },
          field: 'agent.disallowed_tools',
          messageContains: ['Unknown config field'],
        ),
        (updates: {'port': 3000.5}, field: 'port', messageContains: ['must be an integer']),
        (updates: {'port': null}, field: 'port', messageContains: ['cannot be null']),
        (updates: {'host': null}, field: 'host', messageContains: ['cannot be null']),
        (
          updates: {'context.warning_threshold': 49},
          field: 'context.warning_threshold',
          messageContains: ['between 50 and 99'],
        ),
        (
          updates: {'context.warning_threshold': 100},
          field: 'context.warning_threshold',
          messageContains: ['between 50 and 99'],
        ),
        (
          updates: {'context.warning_threshold': 'high'},
          field: 'context.warning_threshold',
          messageContains: ['must be an integer'],
        ),
        (
          updates: {'context.exploration_summary_threshold': 999},
          field: 'context.exploration_summary_threshold',
          messageContains: ['>= 1000'],
        ),
        (
          updates: {'context.exploration_summary_threshold': 'large'},
          field: 'context.exploration_summary_threshold',
          messageContains: ['must be an integer'],
        ),
        (
          updates: {'context.compact_instructions': 123},
          field: 'context.compact_instructions',
          messageContains: ['must be a string'],
        ),
        (
          updates: {'sessions.maintenance.mode': 'invalid'},
          field: 'sessions.maintenance.mode',
          messageContains: ['must be one of'],
        ),
        (
          updates: {'sessions.maintenance.prune_after_days': -1},
          field: 'sessions.maintenance.prune_after_days',
          messageContains: ['must be >='],
        ),
        (
          updates: {'channels.google_chat.group_allowlist': 'spaces/AAA'},
          field: 'channels.google_chat.group_allowlist',
          messageContains: ['must be a list of strings'],
        ),
        (
          updates: {
            'channels.google_chat.dm_allowlist': ['spaces/AAA/users/1', 7],
          },
          field: 'channels.google_chat.dm_allowlist',
          messageContains: ['must contain only strings'],
        ),
      ];

      for (final (:updates, :field, :messageContains) in cases) {
        _expectSingleError(validator.validate(updates), field: field, messageContains: messageContains);
      }
    });

    test('rejects invalid advisor trigger names', () {
      _expectSingleError(
        validator.validate({
          'advisor.triggers': ['explicit', 'bad_trigger'],
        }),
        field: 'advisor.triggers',
        messageContains: ['bad_trigger'],
      );
    });

    test('validates Google Chat enablement requirements', () {
      final missing = validator.validate({'channels.google_chat.enabled': true});
      expect(missing, hasLength(3));
      expect(
        missing.map((error) => error.field).toSet(),
        containsAll([
          'channels.google_chat.service_account',
          'channels.google_chat.audience.type',
          'channels.google_chat.audience.value',
        ]),
      );

      expect(
        validator.validate(
          {'channels.google_chat.enabled': true},
          currentValues: {
            'channels.google_chat.service_account': '/tmp/google-service-account.json',
            'channels.google_chat.audience.type': 'project-number',
            'channels.google_chat.audience.value': '123456789',
          },
        ),
        isEmpty,
      );

      _expectSingleError(
        validator.validate({'channels.google_chat.service_account': '/tmp/sa.json'}),
        field: 'channels.google_chat.service_account',
        messageContains: ['read-only'],
      );
    });

    test('validates GitHub webhook and trigger requirements', () {
      _expectSingleError(
        validator.validate({'github.enabled': true}),
        field: 'github.webhook_secret',
        messageContains: ['required when github.enabled is true'],
      );
      expect(validator.validate({'github.enabled': true}, currentValues: {'github.webhook_secret': 'secret'}), isEmpty);

      final triggerCases = <({Map<String, dynamic> trigger, List<String> messageContains})>[
        (trigger: {'workflow': 'code-review'}, messageContains: ['event']),
        (trigger: {'event': 'pull_request', 'workflow': ''}, messageContains: ['workflow']),
        (
          trigger: {
            'event': 'pull_request',
            'workflow': 'code-review',
            'actions': ['opened', 7],
          },
          messageContains: ['actions'],
        ),
        (
          trigger: {
            'event': 'pull_request',
            'workflow': 'code-review',
            'labels': ['needs-review', 7],
          },
          messageContains: ['labels'],
        ),
      ];
      for (final (:trigger, :messageContains) in triggerCases) {
        _expectSingleError(
          validator.validate({
            'github.triggers': [trigger],
          }),
          field: 'github.triggers',
          messageContains: messageContains,
        );
      }

      expect(
        validator.validate({
          'github.triggers': [
            {
              'event': 'pull_request',
              'workflow': 'code-review',
              'actions': ['opened'],
              'labels': ['needs-review'],
            },
          ],
        }),
        isEmpty,
      );
    });

    test('validates Google Chat space events requirements', () {
      expect(validator.validate({'channels.google_chat.space_events.enabled': false}), isEmpty);

      final missingCases = <({Map<String, dynamic> currentValues, String missingField, List<String> notMissingFields})>[
        (
          currentValues: {
            'channels.google_chat.pubsub.subscription': 'my-sub',
            'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
          },
          missingField: 'channels.google_chat.pubsub.project_id',
          notMissingFields: [
            'channels.google_chat.pubsub.subscription',
            'channels.google_chat.space_events.pubsub_topic',
          ],
        ),
        (
          currentValues: {
            'channels.google_chat.pubsub.project_id': 'my-project',
            'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
          },
          missingField: 'channels.google_chat.pubsub.subscription',
          notMissingFields: ['channels.google_chat.pubsub.project_id'],
        ),
        (
          currentValues: {
            'channels.google_chat.pubsub.project_id': 'my-project',
            'channels.google_chat.pubsub.subscription': 'my-sub',
          },
          missingField: 'channels.google_chat.space_events.pubsub_topic',
          notMissingFields: const [],
        ),
      ];
      for (final (:currentValues, :missingField, :notMissingFields) in missingCases) {
        final fields = validator
            .validate({'channels.google_chat.space_events.enabled': true}, currentValues: currentValues)
            .map((error) => error.field)
            .toSet();
        expect(fields, contains(missingField), reason: missingField);
        for (final field in notMissingFields) {
          expect(fields, isNot(contains(field)), reason: field);
        }
      }

      final completeValues = {
        'channels.google_chat.pubsub.project_id': 'my-project',
        'channels.google_chat.pubsub.subscription': 'my-sub',
        'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
      };
      expect(
        validator.validate({'channels.google_chat.space_events.enabled': true}, currentValues: completeValues),
        isEmpty,
      );
      expect(
        validator.validate(
          {
            'channels.google_chat.space_events.enabled': true,
            'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
          },
          currentValues: {
            'channels.google_chat.pubsub.project_id': 'my-project',
            'channels.google_chat.pubsub.subscription': 'my-sub',
          },
        ),
        isEmpty,
      );
      expect(
        validator
            .validate({'channels.google_chat.space_events.enabled': true})
            .any((error) => error.message.contains('space_events.enabled')),
        isTrue,
      );
    });

    test('returns all independent errors for multi-field updates', () {
      final errors = validator.validate({'port': 0, 'host': '', 'logging.level': 'DEBUG'});
      expect(errors, hasLength(3));
      expect(errors.map((error) => error.field).toSet(), containsAll(['port', 'host', 'logging.level']));
    });

    test('empty map returns empty list', () {
      expect(validator.validate({}), isEmpty);
    });
  });
}

void _expectSingleError(List<ValidationError> errors, {required String field, required List<String> messageContains}) {
  expect(errors, hasLength(1), reason: field);
  expect(errors.first.field, field);
  for (final text in messageContains) {
    expect(errors.first.message, contains(text), reason: field);
  }
}
