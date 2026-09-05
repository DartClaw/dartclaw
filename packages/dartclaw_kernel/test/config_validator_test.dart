import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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
        // -1 is the operator's way to switch the daily reset off.
        {'sessions.reset_hour': -1},
        {'sessions.idle_timeout_minutes': 0},
        {'agent.max_turns': null},
        {'agent.max_turns': 5},
        {'usage.budget_warning_tokens': null},
        {'usage.budget_warning_tokens': 1000},
        {'host': 'localhost'},
        {'agent.model': 'sonnet'},
        {'agent.model': null},
        {'scheduling.heartbeat.enabled': true},
        {'scheduling.heartbeat.enabled': false},
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
        // Channel-package-private and previously boot-YAML-only keys: honoured
        // from YAML for releases, unsettable until they were registered.
        {'channels.whatsapp.gowa_port': 3100},
        {'channels.signal.phone_number': '+15550001111'},
        {'container.image': 'dartclaw-agent:latest'},
        {'dev_mode': false},
        {
          'alerts.targets': [
            {'channel': 'signal', 'recipient': '+15550001111'},
          ],
        },
        {
          'alerts.routes': {
            'credential-health': ['+15550001111'],
          },
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
        (updates: {'sessions.reset_hour': 24}, field: 'sessions.reset_hour', messageContains: ['between -1 and 23']),
        (updates: {'sessions.reset_hour': -2}, field: 'sessions.reset_hour', messageContains: ['between -1 and 23']),
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
          updates: {'scheduling.heartbeat.enabled': 'true'},
          field: 'scheduling.heartbeat.enabled',
          messageContains: ['must be a boolean', 'String'],
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
        // Registered as a string list, so a bare scalar is a type error rather
        // than an unknown field.
        (
          updates: {'agent.disallowed_tools': 'tool1'},
          field: 'agent.disallowed_tools',
          messageContains: ['must be a list of strings'],
        ),
        // Registering credential material described it without making it
        // writable.
        (updates: {'credentials': <String, dynamic>{}}, field: 'credentials', messageContains: ['read-only']),
        (updates: {'guards.enabled': false}, field: 'guards.enabled', messageContains: ['read-only']),
        (updates: {'guards.fail_open': true}, field: 'guards.fail_open', messageContains: ['read-only']),
        (updates: {'container.enabled': false}, field: 'container.enabled', messageContains: ['read-only']),
        (
          updates: {'projects.allowApiLocalPath': true},
          field: 'projects.allowApiLocalPath',
          messageContains: ['read-only'],
        ),
        (
          updates: {
            'projects.localPathAllowlist': ['/'],
          },
          field: 'projects.localPathAllowlist',
          messageContains: ['read-only'],
        ),
        (
          updates: {
            'guards.network.extra_allowed_domains': ['evil.example'],
          },
          field: 'guards.network.extra_allowed_domains',
          messageContains: ['read-only'],
        ),
        (updates: {'tasks.execution': 'host'}, field: 'tasks.execution', messageContains: ['read-only']),
        (
          updates: {'credentials.anthropic.api_key': 'sk-test'},
          field: 'credentials.anthropic.api_key',
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

    test('a bound the loader silently applies is refused at write time instead of discarded at the next boot', () {
      // All five clamps are silent, so today a write above the clamp returns
      // success, reaches dartclaw.yaml and sets restart.pending for a value the
      // clamp throws away at that very restart. The declaration now states the
      // bound; the clamp is untouched, so nothing changes at load.
      const refused = <({Map<String, dynamic> updates, String field, List<String> messageContains})>[
        (
          updates: {'knowledge.inbox.interval_minutes': 5000},
          field: 'knowledge.inbox.interval_minutes',
          messageContains: ['between 1 and 1440', '5000'],
        ),
        (
          updates: {'knowledge.inbox.max_bytes': 999999999},
          field: 'knowledge.inbox.max_bytes',
          messageContains: ['between 1 and 52428800'],
        ),
        (
          updates: {'knowledge.inbox.retry_attempts': 99},
          field: 'knowledge.inbox.retry_attempts',
          messageContains: ['between 0 and 10'],
        ),
        (
          updates: {'knowledge.inbox.processed_retention_days': 3651},
          field: 'knowledge.inbox.processed_retention_days',
          messageContains: ['between 0 and 3650'],
        ),
        (
          updates: {'knowledge.wiki_lint.interval_minutes': 1441},
          field: 'knowledge.wiki_lint.interval_minutes',
          messageContains: ['between 1 and 1440'],
        ),
      ];
      for (final (:updates, :field, :messageContains) in refused) {
        _expectSingleError(validator.validate(updates), field: field, messageContains: messageContains);
      }

      // The bound itself, and everything under it, still writes.
      for (final updates in const <Map<String, dynamic>>[
        {'knowledge.inbox.interval_minutes': 1440},
        {'knowledge.inbox.interval_minutes': 1},
        {'knowledge.inbox.max_bytes': 52428800},
        {'knowledge.inbox.retry_attempts': 10},
        {'knowledge.inbox.retry_attempts': 0},
        {'knowledge.inbox.processed_retention_days': 3650},
        {'knowledge.wiki_lint.interval_minutes': 1440},
      ]) {
        expect(validator.validate(updates), isEmpty, reason: updates.toString());
      }
    });

    test('a declared upper bound no loader enforces no longer refuses the write', () {
      // PubSubConfig enforces only >= 1 and never an upper bound, so the
      // declared max: 60 refused a write the loader would have honoured.
      expect(validator.validate({'channels.google_chat.pubsub.poll_interval_seconds': 61}), isEmpty);
      expect(validator.validate({'channels.google_chat.pubsub.poll_interval_seconds': 3600}), isEmpty);
      _expectSingleError(
        validator.validate({'channels.google_chat.pubsub.poll_interval_seconds': 0}),
        field: 'channels.google_chat.pubsub.poll_interval_seconds',
        messageContains: ['>= 1'],
      );
    });

    test('turn-limit writes validate duration grammar and the merged sibling relation', () {
      expect(
        validator.validate({'governance.turn_limits.stall_timeout': 30.0, 'governance.turn_limits.turn_timeout': 60}),
        isEmpty,
      );
      _expectSingleError(
        validator.validate({'governance.turn_limits.turn_timeout': 'bogus'}),
        field: 'governance.turn_limits.turn_timeout',
        messageContains: ['non-negative duration'],
      );
      _expectSingleError(
        validator.validate(
          {'governance.turn_limits.turn_timeout': '5m'},
          currentValues: {'governance.turn_limits.stall_timeout': const Duration(minutes: 5)},
        ),
        field: 'governance.turn_limits.stall_timeout',
        messageContains: ['less than', 'turn_timeout'],
      );
      expect(
        validator.validate(
          {'governance.turn_limits.turn_timeout': '10m'},
          currentValues: {'governance.turn_limits.stall_timeout': const Duration(minutes: 5)},
        ),
        isEmpty,
      );
    });

    test('tasks.worktree.merge_strategy refuses a value its loader would have thrown away', () {
      // The one allowed-set parse site that does not trim: both 'bogus' and
      // 'merge ' are silently defaulted to squash at load today, so neither
      // write has ever delivered what it asked for.
      expect(validator.validate({'tasks.worktree.merge_strategy': 'squash'}), isEmpty);
      expect(validator.validate({'tasks.worktree.merge_strategy': 'merge'}), isEmpty);
      for (final value in const ['bogus', 'merge ', ' squash']) {
        _expectSingleError(
          validator.validate({'tasks.worktree.merge_strategy': value}),
          field: 'tasks.worktree.merge_strategy',
          messageContains: ['must be one of', 'squash, merge'],
        );
      }
    });

    test('the four allowed sets whose loaders trim stay unenforced on the write path', () {
      // Enforcing these would refuse a trailing-whitespace value that works end
      // to end today, because the write path compares exactly and each of these
      // parse sites trims first. The residual is deliberate and recorded in the
      // disposition table: a non-member write is still accepted here and
      // warned-and-defaulted at the next boot.
      for (final updates in const <Map<String, dynamic>>[
        {'workflow.approvals': 'auto '},
        {'workflow.approvals': 'bogus'},
        {'tasks.completion_action': 'accept '},
        {'tasks.completion_action': 'bogus'},
        {'knowledge.inbox.delivery_mode': 'announce '},
        {'knowledge.wiki_lint.delivery_mode': 'announce '},
      ]) {
        expect(validator.validate(updates), isEmpty, reason: updates.toString());
      }
    });

    test('gateway.auth_mode declares its two values without becoming writable', () {
      final meta = ConfigMeta.fields['gateway.auth_mode']!;
      expect(meta.type, ConfigFieldType.enum_);
      expect(meta.allowedValues, ['token', 'none']);
      expect(meta.mutability, ConfigMutability.readonly);
      // Known -> writable -> constraint ordering: the read-only refusal fires
      // first, so a legal value and an illegal one refuse identically and
      // neither carries a constraint error beside it.
      for (final value in const ['none', 'token', 'basic']) {
        _expectSingleError(
          validator.validate({'gateway.auth_mode': value}),
          field: 'gateway.auth_mode',
          messageContains: ['read-only'],
        );
      }
    });

    test('a nullable field names null in its type label and a non-nullable one does not', () {
      // The rest of this suite asserts message substrings, so a type label that
      // dropped the `or null` half would pass it unnoticed.
      const exact = <String, String>{
        'agent.max_turns': "Field 'agent.max_turns' must be an integer or null, got String",
        'port': "Field 'port' must be an integer, got String",
        'agent.model': "Field 'agent.model' must be a string or null, got int",
        'host': "Field 'host' must be a string, got int",
      };
      for (final entry in exact.entries) {
        final value = entry.value.contains('integer') ? 'x' : 7;
        expect(validator.validate({entry.key: value}).single.message, entry.value, reason: entry.key);
      }
    });

    test('removed advisor.triggers is rejected as an unknown field, not trigger-validated', () {
      _expectSingleError(
        validator.validate({
          'advisor.triggers': ['explicit', 'bad_trigger'],
        }),
        field: 'advisor.triggers',
        messageContains: ['Unknown config field'],
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

      // Each entry is judged against the shape the registry declares for it, so
      // a refusal names the offending entry and field rather than the section.
      final triggerCases = <({Map<String, dynamic> trigger, String field, List<String> messageContains})>[
        (
          trigger: {'event': '', 'workflow': 'code-review'},
          field: 'github.triggers[0].event',
          messageContains: ['must not be empty'],
        ),
        (
          trigger: {'event': 'pull_request', 'workflow': ''},
          field: 'github.triggers[0].workflow',
          messageContains: ['must not be empty'],
        ),
        (
          trigger: {
            'event': 'pull_request',
            'workflow': 'code-review',
            'actions': ['opened', 7],
          },
          field: 'github.triggers[0].actions',
          messageContains: ['strings'],
        ),
        (
          trigger: {
            'event': 'pull_request',
            'workflow': 'code-review',
            'labels': ['needs-review', 7],
          },
          field: 'github.triggers[0].labels',
          messageContains: ['strings'],
        ),
      ];
      for (final (:trigger, :field, :messageContains) in triggerCases) {
        _expectSingleError(
          validator.validate({
            'github.triggers': [trigger],
          }),
          field: field,
          messageContains: messageContains,
        );
      }

      // `event` and `workflow` default at load, so omitting them is legal. The
      // check that used to refuse this contradicted the loader it guards.
      expect(
        validator.validate({
          'github.triggers': [<String, dynamic>{}],
        }),
        isEmpty,
      );

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
