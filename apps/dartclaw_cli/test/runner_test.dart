import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:test/test.dart';

void main() {
  late DartclawRunner runner;

  setUp(() {
    runner = DartclawRunner()
      ..addCommand(ServeCommand())
      ..addCommand(StatusCommand());
  });

  group('DartclawRunner', () {
    test('unknown command throws UsageException', () {
      expect(() => runner.run(['invalid']), throwsA(isA<UsageException>()));
    });

    test('--help produces help text containing serve and status', () {
      final usage = runner.usage;
      expect(usage, contains('serve'));
      expect(usage, contains('status'));
      expect(usage, contains('--token'));
    });

    test('no arguments outputs help text', () async {
      // CommandRunner.run([]) prints usage and returns; does not throw.
      // Verify it completes without error.
      await expectLater(runner.run([]), completes);
    });

    test('description matches expected value', () {
      expect(runner.description, 'DartClaw \u2014 security-conscious AI agent runtime');
    });

    test('executable name is dartclaw', () {
      expect(runner.executableName, 'dartclaw');
    });
  });
}
