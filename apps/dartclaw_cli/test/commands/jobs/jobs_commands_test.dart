import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_create_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_delete_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_list_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Jobs commands', () {
    test('jobs parent registers expected subcommands', () {
      final command = JobsCommand();
      expect(command.subcommands.keys, containsAll(['list', 'create', 'show', 'delete']));
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
  });
}
