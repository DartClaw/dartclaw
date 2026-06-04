import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/token_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory dataDir;
  late File configFile;
  late List<String> stdoutLines;
  late List<String> stderrLines;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('token_command_test_');
    dataDir = Directory(p.join(tempDir.path, 'data'))..createSync();
    configFile = File(p.join(tempDir.path, 'dartclaw.yaml'));
    stdoutLines = <String>[];
    stderrLines = <String>[];
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  CommandRunner<void> makeRunner() => CommandRunner<void>('dartclaw', 'test')
    ..argParser.addOption('config')
    ..addCommand(TokenCommand(stdoutLine: stdoutLines.add, stderrLine: stderrLines.add));

  test('rotate tells operators to restart running servers for file-backed tokens', () async {
    configFile.writeAsStringSync('data_dir: ${dataDir.path}\n');

    await makeRunner().run(['--config', configFile.path, 'token', 'rotate']);

    expect(stdoutLines.single, hasLength(64));
    expect(File(p.join(dataDir.path, 'gateway_token')).readAsStringSync().trim(), stdoutLines.single);
    expect(stderrLines.single, 'Token rotated. Restart any running DartClaw server to use the new token.');
  });

  test('rotate warns when config-backed gateway token is authoritative', () async {
    configFile.writeAsStringSync('''
data_dir: ${dataDir.path}
gateway:
  token: configured-token
''');

    await makeRunner().run(['--config', configFile.path, 'token', 'rotate']);

    expect(stdoutLines.single, hasLength(64));
    expect(
      stderrLines.single,
      'Token file rotated, but this config uses gateway.token. Rotate the config value and restart any running server.',
    );
  });
}
