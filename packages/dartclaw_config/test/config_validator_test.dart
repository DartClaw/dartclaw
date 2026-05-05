import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  late ConfigValidator validator;

  setUp(() {
    validator = const ConfigValidator();
  });

  group('ConfigValidator', () {
    group('int fields — valid', () {
      test('valid port, concurrency and session fields', () {
        expect(validator.validate({'port': 3000}), isEmpty);
        expect(validator.validate({'concurrency.max_parallel_turns': 5}), isEmpty);
        expect(validator.validate({'sessions.reset_hour': 12}), isEmpty);
        expect(validator.validate({'sessions.idle_timeout_minutes': 0}), isEmpty);
      });
    });

    group('int fields — invalid', () {
      test('port 0 below range', () {
        final errors = validator.validate({'port': 0});
        expect(errors, hasLength(1));
        expect(errors.first.field, equals('port'));
        expect(errors.first.message, contains('between 1 and 65535'));
      });

      test('port 65536 above range', () {
        final errors = validator.validate({'port': 65536});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 1 and 65535'));
      });

      test('port string type mismatch', () {
        final errors = validator.validate({'port': 'abc'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be an integer'));
        expect(errors.first.message, contains('String'));
      });

      test('port -1 below range', () {
        final errors = validator.validate({'port': -1});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 1 and 65535'));
      });

      test('worker_timeout 0 below range', () {
        final errors = validator.validate({'worker_timeout': 0});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('>= 1'));
      });

      test('sessions.reset_hour 24 above range', () {
        final errors = validator.validate({'sessions.reset_hour': 24});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 0 and 23'));
      });

      test('sessions.reset_hour -1 below range', () {
        final errors = validator.validate({'sessions.reset_hour': -1});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 0 and 23'));
      });

      test('concurrency.max_parallel_turns 0 below range', () {
        final errors = validator.validate({'concurrency.max_parallel_turns': 0});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 1 and 10'));
      });

      test('concurrency.max_parallel_turns 11 above range', () {
        final errors = validator.validate({'concurrency.max_parallel_turns': 11});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 1 and 10'));
      });
    });

    group('nullable int fields', () {
      test('null and positive values are valid', () {
        expect(validator.validate({'agent.max_turns': null}), isEmpty);
        expect(validator.validate({'agent.max_turns': 5}), isEmpty);
        expect(validator.validate({'usage.budget_warning_tokens': null}), isEmpty);
        expect(validator.validate({'usage.budget_warning_tokens': 1000}), isEmpty);
      });

      test('agent.max_turns 0 below range', () {
        final errors = validator.validate({'agent.max_turns': 0});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('>= 1'));
      });
    });

    group('string fields — valid', () {
      test('non-empty strings and nullable strings pass', () {
        expect(validator.validate({'host': 'localhost'}), isEmpty);
        expect(validator.validate({'agent.model': 'sonnet'}), isEmpty);
        expect(validator.validate({'agent.model': null}), isEmpty);
        expect(validator.validate({'andthen.source_cache_dir': null}), isEmpty);
        expect(validator.validate({'channels.whatsapp.task_trigger.prefix': 'task:'}), isEmpty);
      });
    });

    group('string fields — invalid', () {
      test('host empty string', () {
        final errors = validator.validate({'host': ''});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must not be empty'));
      });

      test('host whitespace-only', () {
        final errors = validator.validate({'host': '  '});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must not be empty'));
      });

      test('host type mismatch', () {
        final errors = validator.validate({'host': 123});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be a string'));
        expect(errors.first.message, contains('int'));
      });

      test('data_dir empty string', () {
        final errors = validator.validate({'data_dir': ''});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must not be empty'));
      });

      test('task trigger prefix whitespace-only', () {
        final errors = validator.validate({'channels.whatsapp.task_trigger.prefix': '   '});
        expect(errors, hasLength(1));
        expect(errors.first.field, 'channels.whatsapp.task_trigger.prefix');
        expect(errors.first.message, contains('must not be empty'));
      });
    });

    group('bool fields', () {
      test('valid bool values pass', () {
        expect(validator.validate({'scheduling.heartbeat.enabled': true}), isEmpty);
        expect(validator.validate({'scheduling.heartbeat.enabled': false}), isEmpty);
      });

      test('scheduling.heartbeat.enabled string type mismatch', () {
        final errors = validator.validate({'scheduling.heartbeat.enabled': 'true'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be a boolean'));
        expect(errors.first.message, contains('String'));
      });
    });

    group('enum fields', () {
      test('task trigger default_type accepts known values', () {
        expect(validator.validate({'channels.google_chat.task_trigger.default_type': 'analysis'}), isEmpty);
      });

      test('task trigger default_type accepts unknown values', () {
        expect(validator.validate({'channels.google_chat.task_trigger.default_type': 'future_type'}), isEmpty);
      });

      test('task trigger default_type still rejects blank strings', () {
        final errors = validator.validate({'channels.google_chat.task_trigger.default_type': '   '});
        expect(errors, hasLength(1));
        expect(errors.first.field, 'channels.google_chat.task_trigger.default_type');
        expect(errors.first.message, contains('must not be empty'));
      });
    });

    group('string list fields', () {
      test('advisor.triggers rejects unknown trigger names', () {
        final errors = validator.validate({
          'advisor.triggers': ['explicit', 'bad_trigger'],
        });
        expect(errors, hasLength(1));
        expect(errors.first.field, 'advisor.triggers');
        expect(errors.first.message, contains('bad_trigger'));
      });

      test('google chat dm_allowlist accepts list of strings', () {
        expect(
          validator.validate({
            'channels.google_chat.dm_allowlist': ['spaces/AAA/users/1'],
          }),
          isEmpty,
        );
      });

      test('google chat group_allowlist rejects non-list value', () {
        final errors = validator.validate({'channels.google_chat.group_allowlist': 'spaces/AAA'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be a list of strings'));
      });

      test('google chat dm_allowlist rejects non-string elements', () {
        final errors = validator.validate({
          'channels.google_chat.dm_allowlist': ['spaces/AAA/users/1', 7],
        });
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must contain only strings'));
      });
    });

    group('google chat cross-field validation', () {
      test('enabled requires service account and audience fields', () {
        final errors = validator.validate({'channels.google_chat.enabled': true});
        expect(errors, hasLength(3));
        final fields = errors.map((error) => error.field).toSet();
        expect(
          fields,
          containsAll([
            'channels.google_chat.service_account',
            'channels.google_chat.audience.type',
            'channels.google_chat.audience.value',
          ]),
        );
      });

      test('enabled passes when required fields already exist in current values', () {
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
      });

      test('credential fields are rejected as read-only', () {
        final errors = validator.validate({'channels.google_chat.service_account': '/tmp/sa.json'});
        expect(errors, hasLength(1));
        expect(errors.first.field, 'channels.google_chat.service_account');
        expect(errors.first.message, contains('read-only'));
      });
    });

    group('github cross-field validation', () {
      test('enabled requires webhook secret', () {
        final errors = validator.validate({'github.enabled': true});
        expect(errors, hasLength(1));
        expect(errors.first.field, 'github.webhook_secret');
        expect(errors.first.message, contains('required when github.enabled is true'));
      });

      test('enabled passes when webhook secret already exists in current values', () {
        expect(
          validator.validate({'github.enabled': true}, currentValues: {'github.webhook_secret': 'secret'}),
          isEmpty,
        );
      });

      test('triggers must be a list of objects with event and workflow', () {
        final errors = validator.validate({
          'github.triggers': [
            {'event': 'pull_request', 'workflow': ''},
          ],
        });
        expect(errors, hasLength(1));
        expect(errors.first.field, 'github.triggers');
        expect(errors.first.message, contains('workflow'));
      });

      test('triggers reject non-string actions or labels', () {
        final errors = validator.validate({
          'github.triggers': [
            {
              'event': 'pull_request',
              'workflow': 'code-review',
              'actions': ['opened', 7],
            },
          ],
        });
        expect(errors, hasLength(1));
        expect(errors.first.field, 'github.triggers');
        expect(errors.first.message, contains('actions'));
      });

      test('valid trigger objects pass validation', () {
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
    });

    group('space events cross-field validation', () {
      test('no error when space_events.enabled is false', () {
        expect(validator.validate({'channels.google_chat.space_events.enabled': false}), isEmpty);
      });

      test('errors when space_events enabled without pubsub.project_id', () {
        final errors = validator.validate(
          {'channels.google_chat.space_events.enabled': true},
          currentValues: {
            'channels.google_chat.pubsub.subscription': 'my-sub',
            'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
          },
        );
        final fields = errors.map((e) => e.field).toSet();
        expect(fields, contains('channels.google_chat.pubsub.project_id'));
        expect(fields, isNot(contains('channels.google_chat.pubsub.subscription')));
        expect(fields, isNot(contains('channels.google_chat.space_events.pubsub_topic')));
      });

      test('errors when space_events enabled without pubsub.subscription', () {
        final errors = validator.validate(
          {'channels.google_chat.space_events.enabled': true},
          currentValues: {
            'channels.google_chat.pubsub.project_id': 'my-project',
            'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
          },
        );
        final fields = errors.map((e) => e.field).toSet();
        expect(fields, contains('channels.google_chat.pubsub.subscription'));
        expect(fields, isNot(contains('channels.google_chat.pubsub.project_id')));
      });

      test('errors when space_events enabled without pubsub_topic', () {
        final errors = validator.validate(
          {'channels.google_chat.space_events.enabled': true},
          currentValues: {
            'channels.google_chat.pubsub.project_id': 'my-project',
            'channels.google_chat.pubsub.subscription': 'my-sub',
          },
        );
        final fields = errors.map((e) => e.field).toSet();
        expect(fields, contains('channels.google_chat.space_events.pubsub_topic'));
      });

      test('no errors when space_events enabled with all required fields', () {
        final errors = validator.validate(
          {'channels.google_chat.space_events.enabled': true},
          currentValues: {
            'channels.google_chat.pubsub.project_id': 'my-project',
            'channels.google_chat.pubsub.subscription': 'my-sub',
            'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
          },
        );
        expect(errors, isEmpty);
      });

      test('uses currentValues for pre-existing fields', () {
        final errors = validator.validate(
          {
            'channels.google_chat.space_events.enabled': true,
            'channels.google_chat.space_events.pubsub_topic': 'projects/p/topics/t',
          },
          currentValues: {
            'channels.google_chat.pubsub.project_id': 'my-project',
            'channels.google_chat.pubsub.subscription': 'my-sub',
          },
        );
        expect(errors, isEmpty);
      });

      test('error message references space_events.enabled as trigger', () {
        final errors = validator.validate({'channels.google_chat.space_events.enabled': true});
        expect(errors.any((e) => e.message.contains('space_events.enabled')), isTrue);
      });
    });

    group('session scope enum fields — valid', () {
      test('all valid dm_scope and group_scope values pass', () {
        expect(validator.validate({'sessions.dm_scope': 'per-contact'}), isEmpty);
        expect(validator.validate({'sessions.dm_scope': 'shared'}), isEmpty);
        expect(validator.validate({'sessions.dm_scope': 'per-channel-contact'}), isEmpty);
        expect(validator.validate({'sessions.group_scope': 'shared'}), isEmpty);
        expect(validator.validate({'sessions.group_scope': 'per-member'}), isEmpty);
      });
    });

    group('session scope enum fields — invalid', () {
      test('sessions.dm_scope invalid value', () {
        final errors = validator.validate({'sessions.dm_scope': 'invalid'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });

      test('sessions.group_scope invalid value', () {
        final errors = validator.validate({'sessions.group_scope': 'invalid'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });

      test('sessions.dm_scope camelCase rejected', () {
        final errors = validator.validate({'sessions.dm_scope': 'perContact'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });
    });

    group('enum fields — valid', () {
      test('valid enum values pass', () {
        expect(validator.validate({'logging.level': 'INFO'}), isEmpty);
        expect(validator.validate({'logging.format': 'human'}), isEmpty);
        expect(validator.validate({'search.backend': 'fts5'}), isEmpty);
        expect(validator.validate({'guards.content.classifier': 'claude_binary'}), isEmpty);
      });
    });

    group('enum fields — invalid', () {
      test('logging.level DEBUG not allowed', () {
        final errors = validator.validate({'logging.level': 'DEBUG'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
        expect(errors.first.message, contains('DEBUG'));
      });

      test('logging.level info case-sensitive', () {
        final errors = validator.validate({'logging.level': 'info'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });

      test('logging.format xml not allowed', () {
        final errors = validator.validate({'logging.format': 'xml'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });

      test('search.backend elasticsearch not allowed', () {
        final errors = validator.validate({'search.backend': 'elasticsearch'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });

      test('guards.content.classifier openai not allowed', () {
        final errors = validator.validate({'guards.content.classifier': 'openai'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });
    });

    group('read-only fields', () {
      test('gateway.auth_mode rejected', () {
        final errors = validator.validate({'gateway.auth_mode': 'none'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('read-only'));
      });

      test('gateway.token rejected', () {
        final errors = validator.validate({'gateway.token': 'secret'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('read-only'));
      });
    });

    group('unknown fields', () {
      test('nonexistent field', () {
        final errors = validator.validate({'nonexistent': 42});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('Unknown config field'));
      });

      test('agent.disallowed_tools excluded list type', () {
        final errors = validator.validate({
          'agent.disallowed_tools': ['tool1'],
        });
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('Unknown config field'));
      });
    });

    group('multiple errors', () {
      test('three fields three errors', () {
        final errors = validator.validate({'port': 0, 'host': '', 'logging.level': 'DEBUG'});
        expect(errors, hasLength(3));
        final fields = errors.map((e) => e.field).toSet();
        expect(fields, containsAll(['port', 'host', 'logging.level']));
      });
    });

    group('empty updates', () {
      test('empty map returns empty list', () {
        expect(validator.validate({}), isEmpty);
      });
    });

    group('int-as-double', () {
      test('port 3000.0 accepted (whole number)', () {
        expect(validator.validate({'port': 3000.0}), isEmpty);
      });

      test('port 3000.5 rejected (not whole number)', () {
        final errors = validator.validate({'port': 3000.5});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be an integer'));
      });
    });

    group('null for non-nullable field', () {
      test('port null rejected', () {
        final errors = validator.validate({'port': null});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('cannot be null'));
      });

      test('host null rejected', () {
        final errors = validator.validate({'host': null});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('cannot be null'));
      });
    });

    group('context fields — valid', () {
      test('valid context values pass', () {
        expect(validator.validate({'context.warning_threshold': 80}), isEmpty);
        expect(validator.validate({'context.warning_threshold': 50}), isEmpty);
        expect(validator.validate({'context.warning_threshold': 99}), isEmpty);
        expect(validator.validate({'context.exploration_summary_threshold': 25000}), isEmpty);
        expect(validator.validate({'context.exploration_summary_threshold': 1000}), isEmpty);
        expect(validator.validate({'context.compact_instructions': 'Preserve key findings'}), isEmpty);
        expect(validator.validate({'context.compact_instructions': null}), isEmpty);
      });
    });

    group('context fields — invalid', () {
      test('warning_threshold below 50', () {
        final errors = validator.validate({'context.warning_threshold': 49});
        expect(errors, hasLength(1));
        expect(errors.first.field, 'context.warning_threshold');
        expect(errors.first.message, contains('between 50 and 99'));
      });

      test('warning_threshold above 99', () {
        final errors = validator.validate({'context.warning_threshold': 100});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 50 and 99'));
      });

      test('warning_threshold type mismatch', () {
        final errors = validator.validate({'context.warning_threshold': 'high'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be an integer'));
      });

      test('exploration_summary_threshold below 1000', () {
        final errors = validator.validate({'context.exploration_summary_threshold': 999});
        expect(errors, hasLength(1));
        expect(errors.first.field, 'context.exploration_summary_threshold');
        expect(errors.first.message, contains('>= 1000'));
      });

      test('exploration_summary_threshold type mismatch', () {
        final errors = validator.validate({'context.exploration_summary_threshold': 'large'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be an integer'));
      });

      test('compact_instructions type mismatch', () {
        final errors = validator.validate({'context.compact_instructions': 123});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be a string'));
      });
    });

    group('session maintenance fields', () {
      test('valid mode values pass', () {
        expect(validator.validate({'sessions.maintenance.mode': 'warn'}), isEmpty);
        expect(validator.validate({'sessions.maintenance.mode': 'enforce'}), isEmpty);
      });

      test('invalid mode fails', () {
        final errors = validator.validate({'sessions.maintenance.mode': 'invalid'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });

      test('sessions.maintenance.prune_after_days: -1 fails', () {
        final errors = validator.validate({'sessions.maintenance.prune_after_days': -1});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be >='));
      });

      test('all int fields with valid values pass', () {
        expect(
          validator.validate({
            'sessions.maintenance.prune_after_days': 30,
            'sessions.maintenance.max_sessions': 500,
            'sessions.maintenance.max_disk_mb': 1024,
            'sessions.maintenance.cron_retention_hours': 24,
            'sessions.maintenance.schedule': '0 4 * * *',
          }),
          isEmpty,
        );
      });
    });
  });
}
