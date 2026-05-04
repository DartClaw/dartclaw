import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/tasks/tasks_command.dart';
import 'package:dartclaw_cli/src/commands/tasks/tasks_create_command.dart';
import 'package:dartclaw_cli/src/commands/tasks/tasks_list_command.dart';
import 'package:dartclaw_cli/src/commands/tasks/tasks_review_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Tasks commands', () {
    test('tasks parent registers expected subcommands', () {
      final command = TasksCommand();
      expect(command.subcommands.keys, containsAll(['list', 'show', 'create', 'start', 'cancel', 'review']));
    });

    test('list renders a task table', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, [
            {
              'id': 'task-12345678',
              'title': 'Investigate CLI',
              'type': 'coding',
              'status': 'running',
              'projectId': 'proj-1',
            },
          ]),
        ],
      );
      final output = <String>[];
      final command = TasksListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list', '--status', 'running']);

      expect(output.join('\n'), contains('Investigate CLI'));
      expect(transport.requests.single.uri.query, contains('status=running'));
    });

    test('create posts the expected payload', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(201, {'id': 'task-1', 'status': 'queued'}),
        ],
      );
      final output = <String>[];
      final command = TasksCreateCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run([
        'create',
        '--title',
        'Investigate',
        '--description',
        'Check the CLI path',
        '--type',
        'coding',
        '--project',
        'proj-1',
        '--provider',
        'codex',
        '--auto-start',
      ]);

      final request = transport.requests.single;
      expect(request.uri.path, '/api/tasks');
      expect(request.body, contains('"projectId":"proj-1"'));
      expect(request.body, contains('"provider":"codex"'));
      expect(request.body, contains('"autoStart":true'));
      expect(output.single, contains('Created task task-1'));
    });

    test('review requires a comment for push_back', () async {
      final command = TasksReviewCommand();
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(() => runner.run(['review', 'task-1', '--action', 'push_back']), throwsA(isA<UsageException>()));
    });
  });
}
