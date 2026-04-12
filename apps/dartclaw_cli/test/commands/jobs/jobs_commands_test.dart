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

    test('list renders scheduled jobs', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, [
            {'name': 'daily-summary', 'schedule': '0 8 * * *', 'type': 'prompt'},
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

      expect(output.join('\n'), contains('daily-summary'));
      expect(output.join('\n'), contains('prompt'));
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
