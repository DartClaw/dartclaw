import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/config/config_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_get_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_set_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_schema_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_show_command.dart';
import 'package:dartclaw_client/dartclaw_client.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../../helpers/fake_api_transport.dart';

void main() {
  group('Config schema', () {
    late List<int> artifact;

    setUpAll(() async {
      final barrel = (await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_cli/src/runner.dart')))!;
      final root = Directory.fromUri(barrel.resolve('../../../../'));
      artifact = File(p.join(root.path, 'schemas', 'dartclaw.schema.json')).readAsBytesSync();
    });

    test('prints the committed artifact byte for byte without a transport', () async {
      final output = <String>[];
      final command = ConfigSchemaCommand(writeLine: output.add);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['schema']);

      expect(utf8.encode('${output.join('\n')}\n'), artifact);
    });

    test('writes and overwrites the committed artifact byte for byte', () async {
      final temp = Directory.systemTemp.createTempSync('config_schema_test_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final target = File(p.join(temp.path, 'dartclaw.schema.json'));
      final output = <String>[];
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(ConfigSchemaCommand(writeLine: output.add));

      await runner.run(['schema', '--out', target.path]);
      expect(target.readAsBytesSync(), artifact);

      target.writeAsStringSync('old schema');
      await runner.run(['schema', '--out', target.path]);
      expect(target.readAsBytesSync(), artifact);
      expect(output, isEmpty);
    });
  });

  group('Config commands', () {
    test('config parent registers expected subcommands', () {
      final command = ConfigCommand();
      expect(command.subcommands.keys, unorderedEquals(['show', 'get', 'set', 'schema']));
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

    test('set sends alerts.targets as a decoded object list, not a string', () async {
      final transport = FakeApiTransport(
        sendResponses: [
          jsonResponse(200, {
            'applied': ['alerts.targets'],
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

      await runner.run(['set', 'alerts.targets', '[{"channel":"signal","recipient":"+1000"}]']);

      expect(transport.requests.single.body, contains('"alerts.targets":[{"channel":"signal","recipient":"+1000"}]'));
      expect(output.single, contains('Applied (reload required)'));
    });
  });
}
