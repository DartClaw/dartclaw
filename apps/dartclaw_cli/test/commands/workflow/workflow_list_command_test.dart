import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_list_command.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show DartclawConfig, ServerConfig;
import 'package:test/test.dart';

void main() {
  group('WorkflowListCommand', () {
    late List<String> output;
    late WorkflowListCommand command;
    late CommandRunner<void> runner;

    setUp(() {
      output = <String>[];
      final config = DartclawConfig(server: ServerConfig(dataDir: '/tmp/dartclaw-test'));
      command = WorkflowListCommand(config: config, writeLine: output.add);
      runner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(command);
    });

    test('name is list', () {
      expect(command.name, 'list');
    });

    test('description is set', () {
      expect(command.description, isNotEmpty);
    });

    test('has --json flag', () {
      expect(command.argParser.options.containsKey('json'), isTrue);
    });

    test('default output is tabular with built-in workflows', () async {
      await runner.run(['list']);

      expect(output, isNotEmpty);
      // Should contain the header
      final joined = output.join('\n');
      expect(joined, contains('Available workflows:'));
      expect(joined, contains('NAME'));
      expect(joined, contains('STEPS'));
      expect(joined, contains('SOURCE'));
      expect(joined, contains('DESCRIPTION'));
      expect(joined, contains('Total:'));
      expect(joined, contains('built-in'));
    });

    test('json output is valid JSON array', () async {
      await runner.run(['list', '--json']);

      expect(output, hasLength(1));
      final decoded = output.first;
      // Should be parseable JSON array
      expect(decoded.trim(), startsWith('['));
      expect(decoded.trim(), endsWith(']'));
    });

    test('json output contains workflow fields', () async {
      await runner.run(['list', '--json']);

      expect(output, hasLength(1));
      expect(output.first, contains('"name"'));
      expect(output.first, contains('"description"'));
      expect(output.first, contains('"stepCount"'));
      expect(output.first, contains('"source"'));
    });

    test('summary line shows built-in count', () async {
      await runner.run(['list']);

      final totalLine = output.lastWhere((l) => l.contains('Total:'));
      expect(totalLine, contains('built-in'));
    });
  });
}
