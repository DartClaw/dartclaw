import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_add_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_list_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_remove_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_show_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';
import '../../helpers/fake_exit.dart';

void main() {
  group('Projects commands', () {
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
      test('remove terminal=$terminal answer=$answer flag=$flag json=$json', () async {
        final payload = {'deleted': 'proj-1'};
        final transport = FakeApiTransport(sendResponses: [jsonResponse(200, payload)]);
        final output = <String>[];
        final errors = <String>[];
        final command = ProjectsRemoveCommand(
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
        final run = runner.run(['remove', 'proj-1', ?flag, if (json) '--json']);
        if (proceeds) {
          await run;
          expect(transport.requests.single.method, 'DELETE');
          expect(transport.requests.single.uri.path, '/api/projects/proj-1');
          expect(output, [json ? const JsonEncoder.withIndent('  ').convert(payload) : 'Removed project proj-1.']);
        } else {
          await expectLater(run, throwsA(isA<FakeExit>().having((e) => e.code, 'code', 1)));
          expect(transport.requests, isEmpty);
          expect(output, isEmpty);
        }
        expect(errors, [
          if (flag == null)
            terminal
                ? 'Remove project proj-1? This also removes related tasks, worktrees, and runtime state. [y/N]'
                : 'Refusing without --yes: stdin is not a terminal.',
          if (!proceeds) 'Project removal aborted.',
        ]);
      });
    }
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
