import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_cli/src/commands/init/init_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_lifecycle_support.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_list_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_show_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
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
        'doctor',
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

    test('S01 lean runner mounts exactly the standalone command set', () async {
      final lean = buildDartclawWorkflowRunner();
      expect(lean.commands.keys.toSet(), {
        'init',
        'rebuild-index',
        'cancel',
        'cleanup-skills',
        'list',
        'pause',
        'resume',
        'retry',
        'run',
        'show',
        'status',
        'validate',
        'help',
      });
      expect(lean.executableName, 'dartclaw-workflow');
      expect(lean.usage, isNot(contains('--server')));
      expect(lean.usage, isNot(contains('--token')));
      for (final name in ['serve', 'workflow', 'runs']) {
        await expectLater(
          lean.run([name]),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              startsWith('Could not find a command named "$name".'),
            ),
          ),
        );
      }
      expect(lean.commands['run']!.invocation, 'dartclaw-workflow run <name>');
      expect(
        buildDartclawRunner().commands['workflow']!.subcommands['run']!.invocation,
        'dartclaw workflow run <name>',
      );
      final output = <String>[];
      await runZoned(
        () => lean.run(['--version']),
        zoneSpecification: ZoneSpecification(print: (_, _, _, line) => output.add(line)),
      );
      expect(output, [dartclawVersion]);
      final runnerLib = (await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_cli/src/runner.dart')))!;
      final packageRoot = p.dirname(p.dirname(p.dirname(runnerLib.toFilePath())));
      expect(
        File(p.join(packageRoot, 'bin', 'dartclaw_workflow.dart')).readAsStringSync(),
        contains('buildDartclawWorkflowRunner()'),
      );
    });

    test('S02 S05 real builders select their respective workflow lanes', () {
      for (final standalone in [true, false]) {
        final shipped = standalone ? buildDartclawWorkflowRunner() : buildDartclawRunner();
        final commands = standalone ? shipped.commands : shipped.commands['workflow']!.subcommands;
        expect((commands['run'] as WorkflowRunCommand).standaloneOnly, standalone);
        expect((commands['list'] as WorkflowListCommand).standaloneOnly, standalone);
        expect((commands['show'] as WorkflowShowCommand).standaloneOnly, standalone);
        expect((commands['status'] as WorkflowStatusCommand).standaloneOnly, standalone);
        for (final name in ['cancel', 'pause', 'resume', 'retry']) {
          expect((commands[name] as StandaloneWorkflowLifecycleCommand).standaloneOnly, standalone, reason: name);
        }
        expect((shipped.commands['init'] as InitCommand).workflowOnly, standalone);
      }
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
