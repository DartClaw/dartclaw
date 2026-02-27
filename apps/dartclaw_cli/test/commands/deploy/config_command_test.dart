import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/deploy/config_command.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('config_cmd_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('ConfigCommand', () {
    test('has correct name and description', () {
      final cmd = ConfigCommand();
      expect(cmd.name, 'config');
      expect(cmd.description, contains('configuration'));
    });

    test('generates firewall rules in output directory', () async {
      final output = <String>[];
      final cmd = ConfigCommand();
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(
        () => runner.run([
          'config',
          '--output-dir=${tmpDir.path}',
          '--data-dir=${tmpDir.path}',
          '--host=localhost',
          '--port=3000',
        ]),
        stdout: () => _CapturingStdout(output),
      );

      final pfFile = File('${tmpDir.path}/firewall/pf.conf');
      final nftFile = File('${tmpDir.path}/firewall/nftables.conf');
      expect(pfFile.existsSync(), isTrue);
      expect(nftFile.existsSync(), isTrue);

      final pfContent = pfFile.readAsStringSync();
      expect(pfContent, contains('api.anthropic.com'));

      final nftContent = nftFile.readAsStringSync();
      expect(nftContent, contains('api.anthropic.com'));
    });

    test('generates service file for current OS', () async {
      final output = <String>[];
      final cmd = ConfigCommand();
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(
        () => runner.run([
          'config',
          '--output-dir=${tmpDir.path}',
          '--data-dir=${tmpDir.path}',
          '--bin-path=/usr/local/bin/dartclaw',
        ]),
        stdout: () => _CapturingStdout(output),
      );

      if (Platform.isMacOS) {
        final plist = File('${tmpDir.path}/com.dartclaw.agent.plist');
        expect(plist.existsSync(), isTrue);
        final content = plist.readAsStringSync();
        expect(content, contains('__ANTHROPIC_API_KEY__'));
        expect(content, contains('/usr/local/bin/dartclaw'));
      } else if (Platform.isLinux) {
        final unit = File('${tmpDir.path}/dartclaw.service');
        expect(unit.existsSync(), isTrue);
        final content = unit.readAsStringSync();
        expect(content, contains('__ANTHROPIC_API_KEY__'));
        expect(content, contains('/usr/local/bin/dartclaw'));
      }
    });

    test('skips existing files without --force', () async {
      // Pre-create a firewall file
      final firewallDir = Directory('${tmpDir.path}/firewall');
      firewallDir.createSync(recursive: true);
      final pfFile = File('${firewallDir.path}/pf.conf');
      pfFile.writeAsStringSync('existing');

      final output = <String>[];
      final cmd = ConfigCommand();
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(
        () => runner.run([
          'config',
          '--output-dir=${tmpDir.path}',
          '--data-dir=${tmpDir.path}',
        ]),
        stdout: () => _CapturingStdout(output),
      );

      // Should skip the existing pf.conf
      expect(output.join('\n'), contains('[SKIP]'));
      expect(pfFile.readAsStringSync(), equals('existing'));
    });

    test('overwrites existing files with --force', () async {
      final firewallDir = Directory('${tmpDir.path}/firewall');
      firewallDir.createSync(recursive: true);
      final pfFile = File('${firewallDir.path}/pf.conf');
      pfFile.writeAsStringSync('existing');

      final output = <String>[];
      final cmd = ConfigCommand();
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(
        () => runner.run([
          'config',
          '--output-dir=${tmpDir.path}',
          '--data-dir=${tmpDir.path}',
          '--force',
        ]),
        stdout: () => _CapturingStdout(output),
      );

      // Should overwrite
      expect(pfFile.readAsStringSync(), isNot(equals('existing')));
      expect(pfFile.readAsStringSync(), contains('api.anthropic.com'));
    });

    test('prints summary with generated file count', () async {
      final output = <String>[];
      final cmd = ConfigCommand();
      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(
        () => runner.run([
          'config',
          '--output-dir=${tmpDir.path}',
          '--data-dir=${tmpDir.path}',
        ]),
        stdout: () => _CapturingStdout(output),
      );

      expect(output.join('\n'), contains('Generated'));
      expect(output.join('\n'), contains('file(s)'));
      expect(output.join('\n'), contains('Next steps'));
    });
  });
}

class _CapturingStdout implements Stdout {
  final List<String> lines;
  _CapturingStdout(this.lines);

  @override
  void writeln([Object? object = '']) {
    lines.add(object.toString());
  }

  @override
  void write(Object? object) {
    lines.add(object.toString());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
