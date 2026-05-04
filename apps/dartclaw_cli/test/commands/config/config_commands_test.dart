import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/config/config_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_get_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_set_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Config commands', () {
    test('config parent registers expected subcommands', () {
      final command = ConfigCommand();
      expect(command.subcommands.keys, containsAll(['show', 'get', 'set']));
    });

    test('show prints values with mutability', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'alerts': {'enabled': true},
            '_meta': const {},
          }),
        ],
      );
      final output = <String>[];
      final command = ConfigShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show']);

      expect(output.join('\n'), contains('alerts.enabled'));
      expect(output.join('\n'), contains('reloadable'));
    });

    test('get resolves dotted keys', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'agent': {'model': 'gpt-5.4'},
            '_meta': const {},
          }),
        ],
      );
      final output = <String>[];
      final command = ConfigGetCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['get', 'agent.model']);

      expect(output.single, 'gpt-5.4');
    });

    test('set reports reload-required fields correctly', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'applied': ['alerts.enabled'],
            'pendingRestart': <String>[],
            'errors': <Map<String, String>>[],
          }),
        ],
      );
      final output = <String>[];
      final command = ConfigSetCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['set', 'alerts.enabled', 'false']);

      expect(transport.requests.single.body, contains('"alerts.enabled":false'));
      expect(output.single, contains('Applied (reload required)'));
    });
  });
}
