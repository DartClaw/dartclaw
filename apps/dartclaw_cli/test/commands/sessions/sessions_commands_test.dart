import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/sessions/sessions_archive_command.dart';
import 'package:dartclaw_cli/src/commands/sessions/sessions_list_command.dart';
import 'package:dartclaw_cli/src/commands/sessions/sessions_show_command.dart';
import 'package:dartclaw_cli/src/commands/sessions_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Sessions commands', () {
    test('sessions parent registers expected subcommands', () {
      final command = SessionsCommand();
      expect(command.subcommands.keys, containsAll(['list', 'show', 'messages', 'delete', 'archive', 'cleanup']));
    });

    test('list renders a session table', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, [
            {'id': 'sess-1', 'type': 'user', 'provider': 'codex', 'updatedAt': '2026-01-01T12:00:00Z'},
          ]),
        ],
      );
      final output = <String>[];
      final command = SessionsListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list', '--type', 'user']);

      expect(output.join('\n'), contains('sess-1'));
      expect(output.join('\n'), contains('codex'));
      expect(transport.requests.single.uri.query, contains('type=user'));
    });

    test('show renders session details', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'id': 'sess-1',
            'type': 'user',
            'provider': 'codex',
            'channelKey': 'web:main',
            'title': 'Main session',
            'createdAt': '2026-01-01T12:00:00Z',
            'updatedAt': '2026-01-01T12:30:00Z',
          }),
        ],
      );
      final output = <String>[];
      final command = SessionsShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show', 'sess-1']);

      expect(output.join('\n'), contains('Main session'));
      expect(transport.requests.single.uri.path, '/api/sessions/sess-1');
    });

    test('archive posts the session archive endpoint', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'id': 'sess-1', 'type': 'archive'}),
        ],
      );
      final output = <String>[];
      final command = SessionsArchiveCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['archive', 'sess-1']);

      expect(transport.requests.single.uri.path, '/api/sessions/sess-1/archive');
      expect(output.single, contains('Archived session sess-1'));
    });
  });
}
