import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
import 'package:path/path.dart' as p;
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

    test('global --version prints dartclawVersion', () async {
      final output = <String>[];
      final versionRunner = DartclawRunner(writeLine: output.add)
        ..addCommand(ServeCommand())
        ..addCommand(StatusCommand());

      await versionRunner.run(['--version']);

      expect(output, [dartclawVersion]);
    });
  });

  group('the shipped command surface', () {
    // Enumerated, not `contains`: a family silently lost to a package move is
    // exactly the failure this pins, and only an exact set can catch it.
    test('buildDartclawRunner registers exactly the retained command families', () {
      expect(buildDartclawRunner().commands.keys.toSet(), {
        'auth',
        'config',
        'google-auth',
        'init',
        'jobs',
        'projects',
        'rebuild-index',
        'runners',
        'secrets',
        'serve',
        'service',
        'sessions',
        // SetupAliasCommand registers under the name 'setup' - the init alias.
        'setup',
        'status',
        'stop',
        'tasks',
        'token',
        'traces',
        'workflow',
        // Registered by CommandRunner itself, not by the application.
        'help',
      });
    });

    test('the entry point runs the builder rather than registering its own set', () async {
      // Resolved through the package URI, not the working directory: suites in
      // this package assign `Directory.current`, and they share a process.
      final runnerLib = (await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_cli/src/runner.dart')))!;
      final packageRoot = p.dirname(p.dirname(p.dirname(runnerLib.toFilePath())));

      expect(
        File(p.join(packageRoot, 'bin', 'dartclaw.dart')).readAsStringSync(),
        contains('buildDartclawRunner()'),
        reason:
            'the set above is only the shipped surface if the binary runs this builder; a second registration list '
            'in the entry point would be a command no operator can reach, with a fully green suite',
      );
    });
  });
}
