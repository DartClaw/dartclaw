import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('ScheduledJob.fromConfig unified type', () {
    test('type: prompt explicit', () {
      final job = ScheduledJob.fromConfig({
        'id': 'daily-report',
        'type': 'prompt',
        'schedule': '0 9 * * *',
        'prompt': 'Generate daily report',
        'delivery': 'none',
      });
      expect(job.jobType, equals(ScheduledJobType.prompt));
      expect(job.taskDefinition, isNull);
    });

    test('defaults to prompt when type omitted', () {
      final job = ScheduledJob.fromConfig({
        'id': 'daily-report',
        'schedule': '0 9 * * *',
        'prompt': 'Generate daily report',
        'delivery': 'none',
      });
      expect(job.jobType, equals(ScheduledJobType.prompt));
    });

    test('type: task with task sub-map', () {
      final job = ScheduledJob.fromConfig({
        'id': 'nightly-analysis',
        'type': 'task',
        'schedule': '0 2 * * *',
        'task': {'title': 'Nightly analysis', 'description': 'Run nightly analysis'},
      });
      expect(job.jobType, equals(ScheduledJobType.task));
      expect(job.taskDefinition, isNotNull);
      expect(job.taskDefinition!.title, equals('Nightly analysis'));
    });

    test('type: task does not require prompt', () {
      // No prompt key — should not throw
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'task-job',
          'type': 'task',
          'schedule': '0 * * * *',
          'task': {'title': 'T', 'description': 'D'},
        }),
        returnsNormally,
      );
    });

    test('type: prompt still requires prompt', () {
      expect(
        () => ScheduledJob.fromConfig({'id': 'prompt-job', 'type': 'prompt', 'schedule': '0 * * * *'}),
        throwsFormatException,
      );
    });

    test('model and effort parsed for prompt jobs', () {
      final job = ScheduledJob.fromConfig({
        'id': 'job',
        'schedule': '0 * * * *',
        'prompt': 'Do something',
        'delivery': 'none',
        'model': 'claude-haiku-4-5',
        'effort': 'low',
      });
      expect(job.model, equals('claude-haiku-4-5'));
      expect(job.effort, equals('low'));
    });

    test('taskDefinition populated for task jobs', () {
      final warnings = <String>[];
      final job = ScheduledJob.fromConfig({
        'id': 'task-job',
        'type': 'task',
        'schedule': '0 0 * * *',
        'task': {'title': 'My Task', 'description': 'Description', 'model': 'claude-sonnet-4-6'},
      }, warnings);
      expect(job.taskDefinition, isNotNull);
      expect(job.taskDefinition!.model, equals('claude-sonnet-4-6'));
      expect(warnings, isEmpty);
    });

    test('taskDefinition ignores an inert legacy category key', () {
      final job = ScheduledJob.fromConfig({
        'id': 'input-review-task',
        'type': 'task',
        'schedule': '0 6 * * *',
        'task': {'title': 'Input Review', 'description': 'Analyze inputs', 'task_type': 'analysis'},
      });
      expect(job.taskDefinition, isNotNull);
      expect(job.taskDefinition!.title, equals('Input Review'));
    });

    test('task job missing task section throws FormatException', () {
      expect(
        () => ScheduledJob.fromConfig({'id': 'broken-task', 'type': 'task', 'schedule': '0 0 * * *'}),
        throwsFormatException,
      );
    });

    test('prompt job model and effort are null when not specified', () {
      final job = ScheduledJob.fromConfig({
        'id': 'plain-job',
        'schedule': '0 * * * *',
        'prompt': 'Do something plain',
        'delivery': 'none',
      });
      expect(job.model, isNull);
      expect(job.effort, isNull);
    });

    test('task job inherits schedule parsed correctly', () {
      final job = ScheduledJob.fromConfig({
        'id': 'cron-task',
        'type': 'task',
        'schedule': '30 8 * * 1',
        'task': {'title': 'Weekly Maintenance', 'description': 'Weekly code review'},
      });
      expect(job.scheduleType, equals(ScheduleType.cron));
      expect(job.cronExpression, isNotNull);
      expect(job.jobType, equals(ScheduledJobType.task));
    });
  });

  // SC02: one composer for config-declared jobs, and one marker that tells them
  // from the built-ins the live applier must never touch.
  group('config-declared jobs', () {
    TaskService taskService() => TaskService(InMemoryTaskRepository());

    test('a parsed entry is marked config-declared and a runtime-built job is not', () {
      final parsed = ScheduledJob.fromConfig({
        'id': 'digest',
        'schedule': '0 9 * * *',
        'prompt': 'Summarize',
        'delivery': 'none',
      });
      final builtIn = ScheduledJob(
        id: 'heartbeat',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 30,
        onExecute: () async => 'beat',
      );

      expect(parsed.isConfigDeclared, isTrue);
      expect(builtIn.isConfigDeclared, isFalse);
    });

    test('the composer returns prompt and task entries, every one config-declared', () {
      final composed = composeConfigJobs(
        SchedulingConfig(
          jobs: [
            {'id': 'digest', 'schedule': '0 9 * * *', 'prompt': 'Summarize', 'delivery': 'none'},
            {
              'id': 'sweep',
              'type': 'task',
              'schedule': '0 2 * * *',
              'task': {'title': 'Sweep', 'description': 'Sweep the inbox'},
            },
          ],
          taskDefinitions: const [
            ScheduledTaskDefinition(
              id: 'sweep',
              cronExpression: '0 2 * * *',
              title: 'Sweep',
              description: 'Sweep the inbox',
            ),
          ],
        ),
        taskService: taskService(),
        credentials: const CredentialsConfig(),
        dataDir: '.dartclaw',
      );

      expect(composed.jobs.map((job) => job.id), ['digest', ScheduledTaskRunner.jobIdForDefinition('sweep')]);
      expect(composed.jobs.every((job) => job.isConfigDeclared), isTrue);
      expect(composed.missedOnceIds, isEmpty);
    });

    test('an unparsable entry is logged and skipped rather than failing the whole list', () {
      final warnings = <String>[];
      final subscription = Logger.root.onRecord
          .where((record) => record.level >= Level.WARNING)
          .listen((record) => warnings.add(record.message));
      addTearDown(subscription.cancel);

      final composed = composeConfigJobs(
        SchedulingConfig(
          jobs: [
            {'id': 'broken', 'schedule': 'not a cron', 'prompt': 'x'},
            {'id': 'digest', 'schedule': '0 9 * * *', 'prompt': 'Summarize'},
          ],
        ),
        taskService: taskService(),
        credentials: const CredentialsConfig(),
        dataDir: '.dartclaw',
      );

      expect(composed.jobs.map((job) => job.id), ['digest']);
      expect(warnings.single, allOf(startsWith('Invalid scheduled job config:'), contains('not a cron')));
    });

    test('a one-time entry whose instant has passed is reported missed, not loaded', () {
      final now = DateTime(2026, 9, 2, 12);
      final composed = composeConfigJobs(
        SchedulingConfig(
          jobs: [
            {
              'id': 'remind-dentist',
              'prompt': 'Remind me',
              'schedule': {'type': 'once', 'at': now.subtract(const Duration(minutes: 1)).toIso8601String()},
            },
            {
              'id': 'remind-later',
              'prompt': 'Remind me later',
              'schedule': {'type': 'once', 'at': now.add(const Duration(minutes: 1)).toIso8601String()},
            },
          ],
        ),
        taskService: taskService(),
        credentials: const CredentialsConfig(),
        dataDir: '.dartclaw',
        now: () => now,
      );

      expect(composed.missedOnceIds, ['remind-dentist']);
      expect(composed.jobs.map((job) => job.id), ['remind-later']);
    });

    test('a one-time entry exactly at the clock is missed — its instant is no longer ahead', () {
      final now = DateTime(2026, 9, 2, 12);
      final composed = composeConfigJobs(
        SchedulingConfig(
          jobs: [
            {
              'id': 'on-the-dot',
              'prompt': 'Now',
              'schedule': {'type': 'once', 'at': now.toIso8601String()},
            },
          ],
        ),
        taskService: taskService(),
        credentials: const CredentialsConfig(),
        dataDir: '.dartclaw',
        now: () => now,
      );

      expect(composed.missedOnceIds, ['on-the-dot']);
      expect(composed.jobs, isEmpty);
    });
  });

  group('ScheduledJob.fromConfig type: shell', () {
    Map<String, dynamic> shellEntry([Map<String, dynamic> overrides = const {}]) => <String, dynamic>{
      'id': 'mail-feed',
      'type': 'shell',
      'schedule': '*/15 * * * *',
      'command': ['/usr/local/bin/hey', 'mail', '--json'],
      'env': {'FEED_TOKEN': 'feed-secret'},
      'output': 'mail.json',
      ...overrides,
    };

    test('a valid entry yields the shell kind with its definition', () {
      final job = ScheduledJob.fromConfig(
        shellEntry({
          'timeout_seconds': 45,
          'retry': {'attempts': 2},
        }),
      );

      expect(job.jobType, ScheduledJobType.shell);
      expect(job.retryAttempts, 2);
      final shell = job.shellDefinition!;
      expect(shell.command, ['/usr/local/bin/hey', 'mail', '--json']);
      expect(shell.env, {'FEED_TOKEN': 'feed-secret'});
      expect(shell.output, 'mail.json');
      expect(shell.timeout, const Duration(seconds: 45));
      expect(shell.enabled, isTrue);
    });

    test('an omitted timeout_seconds takes the documented default, and enabled: false is carried', () {
      final shell = ScheduledJob.fromConfig(shellEntry({'enabled': false})).shellDefinition!;

      expect(shell.timeout, defaultShellJobTimeout);
      expect(shell.timeout, const Duration(seconds: 300));
      expect(shell.enabled, isFalse);
    });

    test('env is optional — a command needing no credential parses', () {
      final entry = shellEntry()..remove('env');

      expect(ScheduledJob.fromConfig(entry).shellDefinition!.env, isEmpty);
    });

    test('refuses a malformed shell entry', () {
      // Each case names the field the operator has to fix; a shell entry that
      // half-loads would run a command nobody wrote.
      void refuses(Map<String, dynamic> entry, String namedField) => expect(
        () => ScheduledJob.fromConfig(entry),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(namedField))),
        reason: 'entry $entry must be refused naming $namedField',
      );

      refuses(shellEntry({'command': <String>[]}), 'command');
      refuses(shellEntry()..remove('command'), 'command');
      refuses(
        shellEntry({
          'command': ['/bin/echo', 7],
        }),
        'command',
      );
      refuses(
        shellEntry({
          'command': ['hey', 'mail'],
        }),
        'command',
      );
      refuses(
        shellEntry({
          'env': {'feed token': 'feed-secret'},
        }),
        'env',
      );
      refuses(
        shellEntry({
          'env': {'FEED_TOKEN': 42},
        }),
        'env',
      );
      refuses(shellEntry({'env': 'feed-secret'}), 'env');
      refuses(shellEntry()..remove('output'), 'output');
      refuses(shellEntry({'output': '  '}), 'output');
      refuses(shellEntry({'output': '/etc/passwd'}), 'output');
      refuses(shellEntry({'output': '../../etc/passwd'}), 'output');
      refuses(shellEntry({'output': r'..\dartclaw.yaml'}), 'output');
      refuses(shellEntry({'output': r'C:\dartclaw\feeds\mail.json'}), 'output');
      refuses(shellEntry({'output': r'\\server\share\mail.json'}), 'output');
      refuses(shellEntry({'timeout_seconds': 0}), 'timeout_seconds');
      // A one-time entry would remove itself from dartclaw.yaml through the
      // applier-less `commit` path, which no file-only refusal guards.
      refuses(
        shellEntry({
          'schedule': {'type': 'once', 'at': '2099-01-01T00:00:00'},
        }),
        'schedule',
      );
      refuses(shellEntry({'timeout_seconds': 'soon'}), 'timeout_seconds');
      for (final key in ['delivery', 'prompt', 'task', 'model', 'effort', 'webhook_url', 'allowed_tools']) {
        refuses(shellEntry({key: 'anything'}), key);
      }
    });

    test('a nested output path stays inside feeds/', () {
      expect(
        ScheduledJob.fromConfig(shellEntry({'output': 'mail/inbox.json'})).shellDefinition!.output,
        'mail/inbox.json',
      );
    });

    test('two entries declaring the same shell work are equal, and any changed field is not', () {
      final base = ScheduledJob.fromConfig(shellEntry()).shellDefinition!;

      expect(ScheduledJob.fromConfig(shellEntry()).shellDefinition, base);
      for (final change in <Map<String, dynamic>>[
        {
          'command': ['/usr/local/bin/hey', 'mail'],
        },
        {
          'env': {'FEED_TOKEN': 'other-secret'},
        },
        {'output': 'other.json'},
        {'timeout_seconds': 45},
        {'enabled': false},
      ]) {
        expect(ScheduledJob.fromConfig(shellEntry(change)).shellDefinition, isNot(base), reason: 'changed $change');
      }
    });
  });
}
