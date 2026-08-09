import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/runners/runners_command.dart';
import 'package:dartclaw_cli/src/commands/runners/runners_list_command.dart';
import 'package:dartclaw_cli/src/commands/runners/runners_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Runners commands', () {
    test('runners parent registers expected subcommands', () {
      final command = RunnersCommand();
      expect(command.subcommands.keys, containsAll(['list', 'show']));
    });

    test('list renders runner rows and a pool footer', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'runners': [
              {'runnerId': 0, 'providerId': 'claude', 'state': 'idle', 'turnsCompleted': 4, 'tokensConsumed': 1234},
            ],
            'pool': {'size': 3, 'activeCount': 1, 'availableCount': 2, 'maxConcurrentWorkers': 3},
          }),
        ],
      );
      final output = <String>[];
      final command = RunnersListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list']);

      expect(output.join('\n'), contains('claude'));
      expect(output.join('\n'), contains('Pool: 3 runners, 1 active, 2 available'));
    });

    test('show prints runner details', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'id': 1, 'provider': 'codex', 'status': 'busy'}),
        ],
      );
      final output = <String>[];
      final command = RunnersShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show', '1']);

      expect(output.join('\n'), contains('provider: codex'));
      expect(transport.requests.single.uri.path, '/api/runners/1');
    });
  });
}
