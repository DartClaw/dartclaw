import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_create_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_delete_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_list_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_run_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Jobs commands', () {
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

    test('list presents the system action persisted lifecycle', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, [
            {
              'id': 'memory-curation',
              'type': 'system_action',
              'schedule': 'on demand',
              'lifecycle': {'state': 'succeeded'},
            },
          ]),
        ],
      );
      final output = <String>[];
      final runner = CommandRunner<void>('dartclaw', 'test')
        ..addCommand(
          JobsListCommand(
            apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
            writeLine: output.add,
          ),
        );

      await runner.run(['list']);

      expect(output.last, contains('system_action (succeeded)'));
      expect(output.last, contains('on demand'));
      expect(output.last, isNot(contains('<invalid>')));
    });

    test('show joins bounded terminal-safe lifecycle and live index evidence', () async {
      final action = 'Stop DartClaw\u0007 then ${List.filled(600, 'x').join()}';
      final payload = {
        'id': 'memory-curation',
        'type': 'system_action',
        'lifecycle': {
          'state': 'conflicted',
          'committedRevision': 43,
          'currentRevision': 44,
          'changedIds': ['A\u001b', 'B'],
          'operationReasons': {'C': 'invalid\u0007 operation'},
          'failureReason': 'proposal\u001b rejected',
          'action': action,
        },
        'index': {'state': 'degraded', 'action': action},
      };
      final transport = FakeApiTransport(sendResponses: [jsonResponse(200, payload), jsonResponse(200, payload)]);
      final output = <String>[];
      final command = JobsShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show', 'memory-curation']);

      expect(
        output,
        containsAll([
          'lifecycle: conflicted',
          'currentRevision: 44',
          'committedRevision: 43',
          'changedIds: A , B',
          'operationReason C: invalid  operation',
          'reason: proposal  rejected',
          'index: degraded',
        ]),
      );
      expect(output, everyElement(allOf(isNot(contains('\u0007')), isNot(contains('\u001b')))));
      expect(output.map((line) => line.length), everyElement(lessThanOrEqualTo(513)));

      output.clear();
      await runner.run(['show', 'memory-curation', '--json']);
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

    test('delete prints restart guidance', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'deleted': 'daily-summary'}),
        ],
      );
      final output = <String>[];
      final command = JobsDeleteCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['delete', 'daily-summary']);

      expect(output.single, contains('Restart the server'));
      expect(transport.requests.single.uri.path, '/api/scheduling/jobs/daily-summary');
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
      test('run encodes $name as exactly one route segment', () async {
        final transport = FakeApiTransport(
          sendResponses: [
            jsonResponse(202, {'name': name, 'status': 'started'}),
          ],
        );
        final output = <String>[];
        final command = JobsRunCommand(
          apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
          writeLine: output.add,
        );
        final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

        await runner.run(['run', name]);

        expect(transport.requests.single.uri.toString(), 'http://localhost:3333/api/scheduling/jobs/$encoded/run');
        expect(transport.requests.single.uri.pathSegments, ['api', 'scheduling', 'jobs', name, 'run']);
        expect(output.single, contains(name));
      });
    }

    test('run prints a 404 restart hint verbatim', () async {
      const message = 'Job is not present in the running scheduler; newly created jobs require a restart.';
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(404, {
            'error': {'code': 'NOT_FOUND', 'message': message},
          }),
        ],
      );
      final output = <String>[];
      final exits = <int>[];
      final command = JobsRunCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
        exitFn: (code) {
          exits.add(code);
          throw const _ExitIntercept();
        },
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(runner.run(['run', 'new-job']), throwsA(isA<_ExitIntercept>()));

      expect(output, [message]);
      expect(exits, [1]);
      expect(output.single, isNot(contains('out of sync')));
    });

    test('run requires a job name', () {
      final command = JobsRunCommand();
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(() => runner.run(['run']), throwsA(isA<UsageException>()));
    });
  });
}

class _ExitIntercept implements Exception {
  const _ExitIntercept();
}
