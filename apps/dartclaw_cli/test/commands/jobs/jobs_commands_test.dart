import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_create_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_delete_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_list_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_run_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_show_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

void main() {
  group('Jobs commands', () {
    for (final (terminal, answer, flag, json, proceeds) in <(bool, String?, String?, bool, bool)>[
      (true, 'y', null, false, true),
      (true, ' YES ', null, true, true),
      (true, 'n', null, false, false),
      (true, '', null, false, false),
      (true, null, null, false, false),
      (false, null, null, false, false),
      (true, null, '-y', false, true),
      (false, null, '--yes', true, true),
    ]) {
      test('delete terminal=$terminal answer=$answer flag=$flag json=$json', () async {
        final payload = {'deleted': 'daily-summary'};
        final transport = FakeApiTransport(sendResponses: [jsonResponse(200, payload)]);
        final output = <String>[];
        final errors = <String>[];
        final command = JobsDeleteCommand(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
          writeLine: output.add,
          stderrLine: errors.add,
          exitFn: fakeExit,
          hasTerminal: () => terminal,
          readLine: () {
            if (!terminal || flag != null) throw StateError('Unexpected prompt');
            return answer;
          },
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
        final run = runner.run(['delete', 'daily-summary', ?flag, if (json) '--json']);
        if (proceeds) {
          await run;
          expect(transport.requests.single.method, 'DELETE');
          expect(transport.requests.single.uri.path, '/api/scheduling/jobs/daily-summary');
          expect(output, [json ? const JsonEncoder.withIndent('  ').convert(payload) : 'Deleted job daily-summary.']);
        } else {
          await expectLater(run, throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)));
          expect(transport.requests, isEmpty);
          expect(output, isEmpty);
        }
        expect(errors, [
          if (flag == null)
            terminal ? 'Delete job daily-summary? [y/N]' : 'Refusing without --yes: stdin is not a terminal.',
          if (!proceeds) 'Job daily-summary not deleted.',
        ]);
      });
    }
    test('jobs parent registers expected subcommands', () {
      final command = JobsCommand();
      expect(command.subcommands.keys, containsAll(['list', 'create', 'show', 'delete', 'run']));
    });

    test('list renders canonical config-defined jobs', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, [
            {
              'id': 'daily-summary',
              'schedule': {'type': 'cron', 'expression': '  0 8 * * *  '},
              'prompt': 'Summarize',
            },
            {'name': 'legacy-task', 'schedule': '  0 9 * * *  ', 'type': 'task'},
            {
              'id': 'health-check',
              'schedule': {'type': 'interval', 'minutes': 5},
              'prompt': 'Check health',
            },
            {
              'id': 'one-time',
              'schedule': {'type': 'once', 'at': '2026-08-08T10:00:00Z'},
              'prompt': 'Run once',
            },
          ]),
        ],
      );
      final output = <String>[];
      final command = JobsListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list']);

      expect(output, [
        '  ID                    SCHEDULE          TYPE',
        '  daily-summary         0 8 * * *         prompt',
        '  legacy-task           0 9 * * *         task',
        '  health-check          every 5 minutes   prompt',
        '  one-time              2026-08-08T10...  prompt',
      ]);
    });

    test('list marks malformed structured schedules as invalid', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, [
            {
              'id': 'bad-cron',
              'schedule': {'type': 'cron'},
            },
            {
              'id': 'bad-interval',
              'schedule': {'type': 'interval', 'minutes': '5'},
            },
            {
              'id': 'bad-once',
              'schedule': {'type': 'once', 'at': 'not-a-date'},
            },
            {
              'id': 'bad-type',
              'schedule': {'type': 'weekly'},
            },
          ]),
        ],
      );
      final output = <String>[];
      final command = JobsListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list']);

      expect(output, [
        '  ID                    SCHEDULE          TYPE',
        '  bad-cron              <invalid>         prompt',
        '  bad-interval          <invalid>         prompt',
        '  bad-once              <invalid>         prompt',
        '  bad-type              <invalid>         prompt',
      ]);
    });

    test('list preserves the raw API payload in JSON mode', () async {
      final jobs = [
        {
          'id': 'daily-summary',
          'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
          'prompt': 'Summarize',
        },
      ];
      final transport = FakeApiTransport(sendResponses: [jsonResponse(200, jobs)]);
      final output = <String>[];
      final command = JobsListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list', '--json']);

      expect(jsonDecode(output.single), jobs);
    });

    // A job's field values reach the terminal verbatim otherwise; control characters
    // and unbounded strings are the two ways a server response could corrupt it.
    test('show renders job fields terminal-safe and bounded', () async {
      final payload = {
        'id': 'daily-summary',
        'schedule': '0 8 * * *',
        'prompt': 'Summarize\u0007 then ${List.filled(600, 'x').join()}',
        'delivery': 'announce\u001b',
      };
      final transport = FakeApiTransport(sendResponses: [jsonResponse(200, payload), jsonResponse(200, payload)]);
      final output = <String>[];
      final command = JobsShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show', 'daily-summary']);

      expect(output, containsAll(['id: daily-summary', 'schedule: 0 8 * * *', 'delivery: announce ']));
      expect(output, everyElement(allOf(isNot(contains('\u0007')), isNot(contains('\u001b')))));
      expect(output.map((line) => line.length), everyElement(lessThanOrEqualTo(513)));

      output.clear();
      await runner.run(['show', 'daily-summary', '--json']);
      expect(jsonDecode(output.single), payload);
    });

    test('create validates cron expressions locally', () {
      final command = JobsCreateCommand();
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(
        () => runner.run(['create', '--name', 'bad-job', '--schedule', 'not-cron', '--prompt', 'Hello']),
        throwsA(isA<UsageException>()),
      );
    });

    test('create posts a task job without a category option', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(201, {
            'job': {'name': 'task-job'},
          }),
        ],
      );
      final command = JobsCreateCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run([
        'create',
        '--name',
        'task-job',
        '--schedule',
        '0 9 * * *',
        '--type',
        'task',
        '--title',
        'Review',
        '--description',
        'Review open work',
      ]);

      expect(transport.requests.single.body, isNot(contains('task_type')));
    });

    test('create refuses the retired task-type option', () {
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(JobsCreateCommand());

      expect(
        () => runner.run([
          'create',
          '--name',
          'task-job',
          '--schedule',
          '0 9 * * *',
          '--type',
          'task',
          '--title',
          'Review',
          '--description',
          'Review open work',
          '--task-type',
          'analysis',
        ]),
        throwsA(isA<UsageException>()),
      );
    });

    test('run starts a job and prints observation guidance', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(202, {'name': 'daily-summary', 'status': 'started'}),
        ],
      );
      final output = <String>[];
      final command = JobsRunCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['run', 'daily-summary']);

      expect(
        output.single,
        allOf(contains('daily-summary'), contains('started'), contains('delivery'), contains('logs')),
      );
      expect(transport.requests.single.uri.path, '/api/scheduling/jobs/daily-summary/run');
    });

    test('run JSON mode prints the API response', () async {
      final response = {'name': 'daily-summary', 'status': 'started'};
      final transport = FakeApiTransport(sendResponses: [jsonResponse(202, response)]);
      final output = <String>[];
      final command = JobsRunCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['run', 'daily-summary', '--json']);

      expect(jsonDecode(output.single), response);
    });

    for (final (name, encoded) in [
      ('Q&A digest', 'Q%26A%20digest'),
      ('percent%job', 'percent%25job'),
      ('slash/job', 'slash%2Fjob'),
      ('already%20encoded', 'already%2520encoded'),
    ]) {
      for (final verb in ['run', 'delete']) {
        test('$verb encodes $name as exactly one route segment', () async {
          final transport = FakeApiTransport(
            sendResponses: [
              jsonResponse(202, {'name': name, 'status': 'started'}),
            ],
          );
          final output = <String>[];
          final client = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);
          final command = verb == 'run'
              ? JobsRunCommand(apiClient: client, writeLine: output.add)
              : JobsDeleteCommand(
                  apiClient: client,
                  writeLine: output.add,
                  stderrLine: (line) => fail(line),
                  exitFn: fakeExit,
                );
          final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

          await runner.run([verb, name, if (verb == 'delete') '--yes']);
          final suffix = verb == 'run' ? '/run' : '';

          expect(transport.requests.single.uri.toString(), 'http://localhost:3333/api/scheduling/jobs/$encoded$suffix');
          expect(transport.requests.single.uri.pathSegments, [
            'api',
            'scheduling',
            'jobs',
            name,
            if (verb == 'run') 'run',
          ]);
          expect(transport.requests.single.method, verb == 'run' ? 'POST' : 'DELETE');
          expect(output.single, contains(name));
        });
      }
    }

    test('run relays a server 404 message verbatim on stderr', () async {
      const message = 'Job was not found.';
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(404, {
            'error': {'code': 'NOT_FOUND', 'message': message},
          }),
        ],
      );
      final output = <String>[];
      final errors = <String>[];
      final command = JobsRunCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
        stderrLine: errors.add,
        exitFn: fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(runner.run(['run', 'new-job']), throwsA(isA<FakeExit>().having((e) => e.code, 'code', 5)));

      expect(output, isEmpty);
      expect(errors, [message]);
      expect(errors.single, isNot(contains('out of sync')));
    });

    test('run requires a job name', () {
      final command = JobsRunCommand();
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(() => runner.run(['run']), throwsA(isA<UsageException>()));
    });
  });
}
