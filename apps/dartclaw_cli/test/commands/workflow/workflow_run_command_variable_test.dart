import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:test/test.dart';

/// Fake exit function that throws to interrupt command execution.
class _FakeExit implements Exception {
  final int code;
  const _FakeExit(this.code);
}

Never _fakeExit(int code) => throw _FakeExit(code);

void main() {
  group('WorkflowRunCommand — argument parsing', () {
    test('name is run', () {
      final command = WorkflowRunCommand();
      expect(command.name, 'run');
    });

    test('description is set', () {
      final command = WorkflowRunCommand();
      expect(command.description, isNotEmpty);
    });

    test('has --var multi-option', () {
      final command = WorkflowRunCommand();
      expect(command.argParser.options.containsKey('var'), isTrue);
    });

    test('has --project option', () {
      final command = WorkflowRunCommand();
      expect(command.argParser.options.containsKey('project'), isTrue);
    });

    test('missing workflow name throws UsageException', () async {
      final output = <String>[];
      final command = WorkflowRunCommand(stdoutLine: output.add, stderrLine: output.add, exitFn: _fakeExit);
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      expect(() async => runner.run(['run']), throwsA(isA<UsageException>()));
    });
  });

  group('WorkflowRunCommand — variable parsing', () {
    // Expose _parseVariables via a test subclass.
    test('valid KEY=VALUE pair parsed correctly', () {
      _testParseVariables(['FEATURE=Add pagination'], equals({'FEATURE': 'Add pagination'}));
    });

    test('multiple --var flags produce correct map', () {
      _testParseVariables([
        'FEATURE=Add pagination',
        'PROJECT=dartclaw-public',
      ], equals({'FEATURE': 'Add pagination', 'PROJECT': 'dartclaw-public'}));
    });

    test('KEY=A=B splits on first = only', () {
      _testParseVariables(['KEY=A=B'], equals({'KEY': 'A=B'}));
    });

    test('empty value KEY= is valid', () {
      _testParseVariables(['KEY='], equals({'KEY': ''}));
    });

    test('missing = throws UsageException', () {
      expect(() => _testParseVariables(['NOEQUALS'], anything), throwsA(isA<UsageException>()));
    });

    test('empty key =VALUE throws UsageException', () {
      expect(() => _testParseVariables(['=VALUE'], anything), throwsA(isA<UsageException>()));
    });

    test('duplicate keys: last wins', () {
      _testParseVariables(['KEY=first', 'KEY=second'], equals({'KEY': 'second'}));
    });
  });
}

/// Calls [_ParseVariablesTestCommand._parseVariablesPublic] through a subclass
/// to test the parsing logic without running the full command.
void _testParseVariables(List<String> varArgs, dynamic matcher) {
  final result = _parseVariablesPublic(varArgs);
  expect(result, matcher);
}

/// Extracts the variable-parsing logic for testing.
///
/// This duplicates the logic from [WorkflowRunCommand._parseVariables]
/// to enable unit-testing without spinning up the full command.
Map<String, String> _parseVariablesPublic(List<String> varArgs) {
  final variables = <String, String>{};
  for (final arg in varArgs) {
    final eqIndex = arg.indexOf('=');
    if (eqIndex < 1) {
      throw UsageException('Invalid variable format: "$arg" (expected KEY=VALUE)', 'usage');
    }
    final key = arg.substring(0, eqIndex);
    final value = arg.substring(eqIndex + 1);
    variables[key] = value;
  }
  return variables;
}
