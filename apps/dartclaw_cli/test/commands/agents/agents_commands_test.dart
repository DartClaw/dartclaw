import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/agents/agents_command.dart';
import 'package:dartclaw_cli/src/commands/agents/agents_list_command.dart';
import 'package:dartclaw_cli/src/commands/agents/agents_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Agents commands', () {
    test('agents parent registers expected subcommands', () {
      final command = AgentsCommand();
      expect(command.subcommands.keys, containsAll(['list', 'show']));
    });

    test('list renders runner rows and a pool footer', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'runners': [
              {'id': 0, 'provider': 'claude', 'status': 'idle', 'turnCount': 4, 'totalTokens': 1234},
            ],
            'pool': {'size': 3, 'activeCount': 1, 'availableCount': 2, 'maxConcurrentTasks': 3},
          }),
        ],
      );
      final output = <String>[];
      final command = AgentsListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list']);

      expect(output.join('\n'), contains('claude'));
      expect(output.join('\n'), contains('Pool: size=3 active=1 available=2'));
    });

    test('show prints runner details', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'id': 1, 'provider': 'codex', 'status': 'busy'}),
        ],
      );
      final output = <String>[];
      final command = AgentsShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show', '1']);

      expect(output.join('\n'), contains('provider: codex'));
      expect(transport.requests.single.uri.path, '/api/agents/1');
    });
  });
}
