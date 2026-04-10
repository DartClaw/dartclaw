import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_validate_command.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show DartclawConfig, ServerConfig;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _validYaml = '''
name: test-workflow
description: A valid test workflow.
steps:
  - id: step1
    name: Step 1
    prompt: Do the thing.
''';

const _warningsOnlyYaml = '''
name: future-workflow
description: Workflow with unknown step type.
steps:
  - id: step1
    name: Step 1
    type: future-type
    prompt: Do the thing.
''';

const _validationErrorYaml = '''
name: error-workflow
description: Workflow with a hard error.
steps:
  - id: gate
    name: Gate
    type: approval
    parallel: true
''';

const _malformedYaml = 'name: : bad: yaml: {{{{';

const _missingDescriptionYaml = '''
name: missing-description
steps:
  - id: step1
    name: Step 1
    prompt: Do the thing.
''';

const _unsupportedContinuityYaml = '''
name: continue-session-workflow
description: Workflow using continueSession with claude.
steps:
  - id: step1
    name: Step 1
    prompt: Do the thing.
  - id: step2
    name: Step 2
    prompt: Follow up.
    continueSession: true
    provider: claude
''';

void main() {
  late Directory tempDir;
  late List<String> output;
  late WorkflowValidateCommand command;
  late CommandRunner<void> runner;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_validate_test_');
    output = <String>[];
    final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
    command = WorkflowValidateCommand(config: config, writeLine: output.add);
    runner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(command);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String writeFixture(String name, String content) {
    final file = File(p.join(tempDir.path, name));
    file.writeAsStringSync(content);
    return file.path;
  }

  group('WorkflowValidateCommand', () {
    test('name is validate', () {
      expect(command.name, 'validate');
    });

    test('description is set', () {
      expect(command.description, isNotEmpty);
    });

    test('missing path argument throws UsageException', () async {
      expect(() => runner.run(['validate']), throwsA(isA<UsageException>()));
    });

    test('valid workflow: exits 0 and prints OK result', () async {
      final path = writeFixture('valid.yaml', _validYaml);
      await runner.run(['validate', path]);

      final joined = output.join('\n');
      expect(exitCode, 0);
      expect(joined, contains('Result: OK'));
      expect(joined, isNot(contains('Validation errors')));
      expect(joined, isNot(contains('Warnings')));
    });

    test('valid workflow: output contains the path', () async {
      final path = writeFixture('valid.yaml', _validYaml);
      await runner.run(['validate', path]);

      final joined = output.join('\n');
      expect(joined, contains(path));
    });

    test('warnings-only workflow: exits 0 and shows warnings section', () async {
      final path = writeFixture('warnings.yaml', _warningsOnlyYaml);
      await runner.run(['validate', path]);

      final joined = output.join('\n');
      expect(exitCode, 0);
      expect(joined, contains('Warnings'));
      expect(joined, contains('Result: OK with warnings'));
      expect(joined, isNot(contains('Validation errors')));
    });

    test('validation error workflow: exits 1 and shows errors section', () async {
      final path = writeFixture('error.yaml', _validationErrorYaml);
      await runner.run(['validate', path]);

      final joined = output.join('\n');
      expect(exitCode, 1);
      expect(joined, contains('Validation errors'));
      expect(joined, contains('Result: INVALID'));
    });

    test('schema validation failure: exits 1', () async {
      final path = writeFixture('missing-desc.yaml', _missingDescriptionYaml);
      await runner.run(['validate', path]);

      expect(exitCode, 1);
      final joined = output.join('\n');
      expect(joined, contains('INVALID'));
    });

    test('empty configured continuity-provider set still rejects unsupported continueSession usage', () async {
      final path = writeFixture('continue-session.yaml', _unsupportedContinuityYaml);
      await runner.run(['validate', path]);

      expect(exitCode, 1);
      final joined = output.join('\n');
      expect(joined, contains('continueSession'));
      expect(joined, contains('provider "claude"'));
    });

    test('malformed YAML: exits 1 and shows parse error', () async {
      final path = writeFixture('malformed.yaml', _malformedYaml);
      await runner.run(['validate', path]);

      expect(exitCode, 1);
      final joined = output.join('\n');
      expect(joined, contains('Parse error'));
    });

    test('non-existent file: exits 1', () async {
      await runner.run(['validate', '/non/existent/path.yaml']);

      expect(exitCode, 1);
    });

    test('warnings-only parity: same file passes registry loading', () async {
      // A warnings-only fixture should both:
      //   (1) exit 0 through workflow validate
      //   (2) load through registry without exclusion
      // This test proves (1). Registry test file proves (2) with the same fixture.
      final path = writeFixture('warnings.yaml', _warningsOnlyYaml);
      await runner.run(['validate', path]);

      expect(exitCode, 0, reason: 'Warnings-only definition should exit 0');
    });

    test('error fixture parity: same file is excluded by registry', () async {
      // A hard-error fixture should both:
      //   (1) exit non-zero through workflow validate
      //   (2) be excluded from registry loading
      // This test proves (1). Registry test file proves (2) with the same fixture.
      final path = writeFixture('error.yaml', _validationErrorYaml);
      await runner.run(['validate', path]);

      expect(exitCode, 1, reason: 'Hard-error definition should exit 1');
    });

    test('output sections: errors appear before warnings', () async {
      // A workflow with both errors and warnings.
      const bothYaml = '''
name: both-issues
description: Workflow with both errors and warnings.
steps:
  - id: gate
    name: Gate
    type: approval
    parallel: true
  - id: future-step
    name: Future
    type: future-type
    prompt: p
''';
      final path = writeFixture('both.yaml', bothYaml);
      await runner.run(['validate', path]);

      final joined = output.join('\n');
      final errorsPos = joined.indexOf('Validation errors');
      final warningsPos = joined.indexOf('Warnings');
      expect(errorsPos, isNot(-1));
      expect(warningsPos, isNot(-1));
      expect(errorsPos, lessThan(warningsPos), reason: 'Errors should appear before warnings');
    });
  });
}
