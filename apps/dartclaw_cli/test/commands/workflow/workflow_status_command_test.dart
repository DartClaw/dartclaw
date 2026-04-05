import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_status_command.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show DartclawConfig, ServerConfig;
import 'package:dartclaw_storage/dartclaw_storage.dart' show openTaskDbInMemory;
import 'package:test/test.dart';

class _FakeExit implements Exception {
  final int code;
  const _FakeExit(this.code);
}

Never _fakeExit(int code) => throw _FakeExit(code);

void main() {
  group('WorkflowStatusCommand', () {
    test('name is status', () {
      expect(WorkflowStatusCommand().name, 'status');
    });

    test('description is set', () {
      expect(WorkflowStatusCommand().description, isNotEmpty);
    });

    test('has --json flag', () {
      expect(WorkflowStatusCommand().argParser.options.containsKey('json'), isTrue);
    });

    test('missing run ID throws UsageException', () {
      final output = <String>[];
      final command = WorkflowStatusCommand(
        writeLine: output.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(
        () => runner.run(['status']),
        throwsA(isA<UsageException>()),
      );
    });

    test('non-existent run ID prints error and exits 1', () async {
      final output = <String>[];
      final tmpDb = openTaskDbInMemory();
      addTearDown(tmpDb.close);

      final config = DartclawConfig(
        server: ServerConfig(dataDir: '/tmp/dartclaw-status-test'),
      );

      final command = WorkflowStatusCommand(
        config: config,
        taskDbFactory: (_) => tmpDb,
        writeLine: output.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['status', 'nonexistent-run-id']),
        throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 1)),
      );
    });
  });
}
