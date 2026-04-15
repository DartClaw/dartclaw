import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_add_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_list_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_remove_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Projects commands', () {
    test('projects parent registers expected subcommands', () {
      final command = ProjectsCommand();
      expect(command.subcommands.keys, containsAll(['list', 'add', 'show', 'fetch', 'remove']));
    });

    test('list renders a project table', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, [
            {
              'id': 'proj-1',
              'name': 'dartclaw',
              'remoteUrl': 'git@example.com:dartclaw.git',
              'defaultBranch': 'main',
              'status': 'ready',
            },
          ]),
        ],
      );
      final output = <String>[];
      final command = ProjectsListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list']);

      expect(output.join('\n'), contains('dartclaw'));
      expect(output.join('\n'), contains('ready'));
    });

    test('add posts the expected payload', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(201, {'id': 'proj-1', 'status': 'cloning'}),
        ],
      );
      final output = <String>[];
      final command = ProjectsAddCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run([
        'add',
        '--name',
        'dartclaw',
        '--remote-url',
        'git@example.com:dartclaw.git',
        '--branch',
        'main',
      ]);

      expect(transport.requests.single.body, contains('"remoteUrl":"git@example.com:dartclaw.git"'));
      expect(output.single, contains('Added project proj-1'));
    });

    test('remove skips confirmation when stdin is not a tty', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'deleted': 'proj-1'}),
        ],
      );
      final output = <String>[];
      final command = ProjectsRemoveCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
        hasTerminal: () => false,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['remove', 'proj-1']);

      expect(transport.requests.single.uri.path, '/api/projects/proj-1');
      expect(output.single, contains('Removed project proj-1'));
    });

    test('show renders project auth details', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'id': 'proj-1',
            'name': 'dartclaw',
            'remoteUrl': 'git@github.com:acme/dartclaw.git',
            'defaultBranch': 'main',
          }),
          jsonResponse(200, {
            'status': 'error',
            'cloneExists': true,
            'lastFetchAt': null,
            'errorMessage': 'Clone failed',
            'auth': {
              'compatible': false,
              'repository': 'acme/dartclaw',
              'credentialsRef': 'github-main',
              'errorMessage': 'GitHub token "github-main" cannot access acme/dartclaw.',
            },
          }),
        ],
      );
      final output = <String>[];
      final command = ProjectsShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show', 'proj-1']);

      final rendered = output.join('\n');
      expect(rendered, contains('Auth:       error'));
      expect(rendered, contains('Repo:       acme/dartclaw'));
      expect(rendered, contains('Credential: github-main'));
    });
  });
}
