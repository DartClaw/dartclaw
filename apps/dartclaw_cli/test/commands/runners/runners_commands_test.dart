import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

    test('list renders runner roles and execution capacity', () async {
      final transport = FakeApiTransport(sendResponses: [jsonResponse(200, await _runnerApiListFixture())]);
      final output = <String>[];
      final command = RunnersListCommand(
        apiClient: DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport),
        writeLine: output.add,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['list']);

      final rendered = output.join('\n');
      expect(rendered, contains('primary'));
      expect(rendered, contains('worker'));
      expect(rendered, contains('Observed runners: 2'));
      expect(rendered, contains('Primary lane: idle'));
      expect(
        rendered,
        contains(
          'Worker capacity: 1 configured, 1 effective, 1 active, 0 available, 0 queued, 0 cached, 0 quarantined',
        ),
      );
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

Future<Map<String, dynamic>> _runnerApiListFixture() async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_testing/fixtures/runner_api_list.json'));
  if (uri == null) throw StateError('Runner API fixture is unavailable.');
  return jsonDecode(await File.fromUri(uri).readAsString()) as Map<String, dynamic>;
}
