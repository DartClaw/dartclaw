import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_command.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowCommand', () {
    late WorkflowCommand command;

    setUp(() {
      command = WorkflowCommand();
    });

    test('name is workflow', () {
      expect(command.name, 'workflow');
    });

    test('description is set', () {
      expect(command.description, isNotEmpty);
    });

    test('has list subcommand', () {
      expect(command.subcommands.containsKey('list'), isTrue);
    });

    test('has run subcommand', () {
      expect(command.subcommands.containsKey('run'), isTrue);
    });

    test('has status subcommand', () {
      expect(command.subcommands.containsKey('status'), isTrue);
    });

    test('has validate subcommand', () {
      expect(command.subcommands.containsKey('validate'), isTrue);
    });

    test('workflow --help shows four subcommands', () {
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);
      expect(runner.commands.containsKey('workflow'), isTrue);
      expect(command.subcommands.length, 4);
    });
  });
}
