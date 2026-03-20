import 'dart:io';

import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late StatusCommand statusCommand;

  setUp(() {
    statusCommand = StatusCommand();
  });

  group('StatusCommand', () {
    test('name is status', () {
      expect(statusCommand.name, 'status');
    });

    test('description is set', () {
      expect(statusCommand.description, isNotEmpty);
    });

    test('has no custom options', () {
      expect(statusCommand.argParser.options.keys, equals(['help']));
    });

    test('missing data directory prints informative message', () async {
      final output = <String>[];
      final globalDir = '${Directory.systemTemp.path}/dartclaw-status-missing-${DateTime.now().microsecondsSinceEpoch}';

      final config = DartclawConfig(server: ServerConfig(dataDir: globalDir));
      final command = StatusCommand(config: config, writeLine: output.add);

      await command.run();
      expect(output, equals(['No data directory found at $globalDir']));
    });

    test('existing data directory prints session count and worker status line', () async {
      final output = <String>[];
      final tmp = await Directory.systemTemp.createTemp('dartclaw-status-test-');
      final sessionsDir = Directory('${tmp.path}/sessions');
      sessionsDir.createSync(recursive: true);

      // Create a session
      final sessions = SessionService(baseDir: sessionsDir.path);
      await sessions.createSession();

      addTearDown(() async {
        if (tmp.existsSync()) {
          await tmp.delete(recursive: true);
        }
      });

      final config = DartclawConfig(server: ServerConfig(dataDir: tmp.path, claudeExecutable: '/usr/local/bin/claude'));
      final command = StatusCommand(config: config, writeLine: output.add);

      await command.run();

      expect(output, hasLength(4));
      expect(output[0], equals('DartClaw Status'));
      expect(output[1], contains('Data dir:  ${tmp.path}'));
      expect(output[2], equals('  Sessions:  1'));
      expect(output[3], equals('  Harness:   not running (executable: /usr/local/bin/claude)'));
    });
  });
}
