import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/deploy/setup_command.dart';
import 'package:test/test.dart';

void main() {
  group('SetupCommand', () {
    test('has correct name and description', () {
      final cmd = SetupCommand();
      expect(cmd.name, 'setup');
      expect(cmd.description, contains('prerequisites'));
    });

    test('reports Docker pass when docker succeeds', () async {
      final output = <String>[];
      final cmd = SetupCommand(run: (exe, args) async => ProcessResult(0, 0, '', ''));

      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(() => runner.run(['setup']), stdout: () => _CapturingStdout(output));

      expect(output.join('\n'), contains('[PASS] Docker'));
    });

    test('reports Docker fail when docker returns non-zero', () async {
      final output = <String>[];
      final cmd = SetupCommand(
        run: (exe, args) async {
          if (exe == 'docker') return ProcessResult(0, 1, '', 'error');
          return ProcessResult(0, 0, '', '');
        },
      );

      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(() => runner.run(['setup']), stdout: () => _CapturingStdout(output));

      expect(output.join('\n'), contains('[FAIL] Docker'));
    });

    test('reports Docker fail when docker throws', () async {
      final output = <String>[];
      final cmd = SetupCommand(
        run: (exe, args) async {
          if (exe == 'docker') throw const OSError('not found');
          return ProcessResult(0, 0, '', '');
        },
      );

      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(() => runner.run(['setup']), stdout: () => _CapturingStdout(output));

      expect(output.join('\n'), contains('[FAIL] Docker not found'));
    });

    test('reports dartclaw warn when binary not in PATH', () async {
      final output = <String>[];
      final cmd = SetupCommand(
        run: (exe, args) async {
          if (exe == 'dartclaw') throw const OSError('not found');
          return ProcessResult(0, 0, '', '');
        },
      );

      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(() => runner.run(['setup']), stdout: () => _CapturingStdout(output));

      expect(output.join('\n'), contains('[WARN] dartclaw binary not in PATH'));
    });

    test('reports OS pass on macOS or Linux', () async {
      final output = <String>[];
      final cmd = SetupCommand(run: (exe, args) async => ProcessResult(0, 0, '', ''));

      final runner = CommandRunner<void>('test', 'test')..addCommand(cmd);

      await IOOverrides.runZoned(() => runner.run(['setup']), stdout: () => _CapturingStdout(output));

      // On macOS CI or Linux CI, OS check should pass
      expect(output.join('\n'), contains('[PASS] OS:'));
    });
  });
}

/// Captures stdout lines for assertion.
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

  // Minimal stubs for unused Stdout members.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
