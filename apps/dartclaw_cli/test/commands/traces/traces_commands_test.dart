import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/traces/traces_command.dart';
import 'package:dartclaw_cli/src/commands/traces/traces_list_command.dart';
import 'package:dartclaw_cli/src/commands/traces/traces_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Traces commands', () {
    test('traces parent registers expected subcommands', () {
      final command = TracesCommand();
      expect(command.subcommands.keys, containsAll(['list', 'show']));
    });

    test('list converts relative since values and renders traces', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'traces': [
              {
                'id': 'trace-1',
                'sessionId': 'sess-1',
                'provider': 'claude',
                'model': 'sonnet',
                'durationMs': 3000,
                'totalTokens': 120,
                'toolCalls': const [],
              },
            ],
            'summary': {'traceCount': 1},
          }),
        ],
      );
      final output = <String>[];
      final command = TracesListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list', '--since', '1h', '--provider', 'claude']);

      expect(output.join('\n'), contains('trace-1'));
      expect(transport.requests.single.uri.queryParameters['provider'], 'claude');
      expect(transport.requests.single.uri.queryParameters['since'], isNotEmpty);
    });

    test('show prints trace detail', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {'id': 'trace-1', 'provider': 'claude', 'totalTokens': 123}),
        ],
      );
      final output = <String>[];
      final command = TracesShowCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['show', 'trace-1']);

      expect(output.join('\n'), contains('provider: claude'));
      expect(transport.requests.single.uri.path, '/api/traces/trace-1');
    });
  });
}
