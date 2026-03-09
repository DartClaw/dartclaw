import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  late ConfigValidator validator;

  setUp(() {
    validator = const ConfigValidator();
  });

  group('ConfigValidator', () {
    group('int fields — valid', () {
      test('port 3000', () {
        expect(validator.validate({'port': 3000}), isEmpty);
      });

      test('port 1 (boundary)', () {
        expect(validator.validate({'port': 1}), isEmpty);
      });

      test('port 65535 (boundary)', () {
        expect(validator.validate({'port': 65535}), isEmpty);
      });

      test('concurrency.max_parallel_turns 5', () {
        expect(
            validator.validate({'concurrency.max_parallel_turns': 5}), isEmpty);
      });

      test('sessions.reset_hour 0 (boundary)', () {
        expect(validator.validate({'sessions.reset_hour': 0}), isEmpty);
      });

      test('sessions.reset_hour 23 (boundary)', () {
        expect(validator.validate({'sessions.reset_hour': 23}), isEmpty);
      });

      test('sessions.idle_timeout_minutes 0 (min 0)', () {
        expect(
            validator.validate({'sessions.idle_timeout_minutes': 0}), isEmpty);
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
        final errors =
            validator.validate({'concurrency.max_parallel_turns': 0});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 1 and 10'));
      });

      test('concurrency.max_parallel_turns 11 above range', () {
        final errors =
            validator.validate({'concurrency.max_parallel_turns': 11});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('between 1 and 10'));
      });
    });

    group('nullable int fields', () {
      test('agent.max_turns null is valid', () {
        expect(validator.validate({'agent.max_turns': null}), isEmpty);
      });

      test('agent.max_turns 5 is valid', () {
        expect(validator.validate({'agent.max_turns': 5}), isEmpty);
      });

      test('agent.max_turns 0 below range', () {
        final errors = validator.validate({'agent.max_turns': 0});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('>= 1'));
      });

      test('usage.budget_warning_tokens null is valid', () {
        expect(
            validator.validate({'usage.budget_warning_tokens': null}), isEmpty);
      });

      test('usage.budget_warning_tokens 1000 is valid', () {
        expect(validator.validate({'usage.budget_warning_tokens': 1000}),
            isEmpty);
      });
    });

    group('string fields — valid', () {
      test('host localhost', () {
        expect(validator.validate({'host': 'localhost'}), isEmpty);
      });

      test('host 0.0.0.0', () {
        expect(validator.validate({'host': '0.0.0.0'}), isEmpty);
      });

      test('agent.model string', () {
        expect(
            validator.validate({'agent.model': 'claude-sonnet-4-6'}), isEmpty);
      });

      test('agent.model null (nullable)', () {
        expect(validator.validate({'agent.model': null}), isEmpty);
      });

      test('guards.content.model string', () {
        expect(
          validator.validate(
              {'guards.content.model': 'claude-haiku-4-5-20251001'}),
          isEmpty,
        );
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
    });

    group('bool fields', () {
      test('agent.context_1m true', () {
        expect(validator.validate({'agent.context_1m': true}), isEmpty);
      });

      test('agent.context_1m false', () {
        expect(validator.validate({'agent.context_1m': false}), isEmpty);
      });

      test('agent.context_1m string type mismatch', () {
        final errors = validator.validate({'agent.context_1m': 'true'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be a boolean'));
        expect(errors.first.message, contains('String'));
      });

      test('scheduling.heartbeat.enabled true (live-mutable)', () {
        expect(
            validator.validate({'scheduling.heartbeat.enabled': true}),
            isEmpty);
      });
    });

    group('session scope enum fields — valid', () {
      test('sessions.dm_scope per-contact', () {
        expect(validator.validate({'sessions.dm_scope': 'per-contact'}), isEmpty);
      });

      test('sessions.dm_scope shared', () {
        expect(validator.validate({'sessions.dm_scope': 'shared'}), isEmpty);
      });

      test('sessions.dm_scope per-channel-contact', () {
        expect(validator.validate({'sessions.dm_scope': 'per-channel-contact'}), isEmpty);
      });

      test('sessions.group_scope shared', () {
        expect(validator.validate({'sessions.group_scope': 'shared'}), isEmpty);
      });

      test('sessions.group_scope per-member', () {
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
      test('logging.level INFO', () {
        expect(validator.validate({'logging.level': 'INFO'}), isEmpty);
      });

      test('logging.level FINE', () {
        expect(validator.validate({'logging.level': 'FINE'}), isEmpty);
      });

      test('logging.format human', () {
        expect(validator.validate({'logging.format': 'human'}), isEmpty);
      });

      test('logging.format json', () {
        expect(validator.validate({'logging.format': 'json'}), isEmpty);
      });

      test('search.backend fts5', () {
        expect(validator.validate({'search.backend': 'fts5'}), isEmpty);
      });

      test('guards.content.classifier claude_binary', () {
        expect(
          validator.validate({'guards.content.classifier': 'claude_binary'}),
          isEmpty,
        );
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
        final errors =
            validator.validate({'guards.content.classifier': 'openai'});
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
        final errors =
            validator.validate({'agent.disallowed_tools': ['tool1']});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('Unknown config field'));
      });
    });

    group('multiple errors', () {
      test('three fields three errors', () {
        final errors = validator.validate({
          'port': 0,
          'host': '',
          'logging.level': 'DEBUG',
        });
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

    group('session maintenance fields', () {
      test('sessions.maintenance.mode: warn passes', () {
        expect(
          validator.validate({'sessions.maintenance.mode': 'warn'}),
          isEmpty,
        );
      });

      test('sessions.maintenance.mode: enforce passes', () {
        expect(
          validator.validate({'sessions.maintenance.mode': 'enforce'}),
          isEmpty,
        );
      });

      test('sessions.maintenance.mode: invalid fails', () {
        final errors = validator.validate({'sessions.maintenance.mode': 'invalid'});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be one of'));
      });

      test('sessions.maintenance.prune_after_days: 0 passes (min boundary)', () {
        expect(
          validator.validate({'sessions.maintenance.prune_after_days': 0}),
          isEmpty,
        );
      });

      test('sessions.maintenance.prune_after_days: -1 fails', () {
        final errors = validator.validate({'sessions.maintenance.prune_after_days': -1});
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('must be >='));
      });

      test('sessions.maintenance.max_sessions: 0 passes', () {
        expect(
          validator.validate({'sessions.maintenance.max_sessions': 0}),
          isEmpty,
        );
      });

      test('sessions.maintenance.max_disk_mb: 0 passes', () {
        expect(
          validator.validate({'sessions.maintenance.max_disk_mb': 0}),
          isEmpty,
        );
      });

      test('sessions.maintenance.cron_retention_hours: 0 passes', () {
        expect(
          validator.validate({'sessions.maintenance.cron_retention_hours': 0}),
          isEmpty,
        );
      });

      test('sessions.maintenance.schedule: valid string passes', () {
        expect(
          validator.validate({'sessions.maintenance.schedule': '0 4 * * *'}),
          isEmpty,
        );
      });

      test('all int fields with valid values pass', () {
        expect(
          validator.validate({
            'sessions.maintenance.prune_after_days': 30,
            'sessions.maintenance.max_sessions': 500,
            'sessions.maintenance.max_disk_mb': 1024,
            'sessions.maintenance.cron_retention_hours': 24,
          }),
          isEmpty,
        );
      });
    });
  });
}
