import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_validate_command.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, ServerConfig;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SkillIntrospector;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Records probe calls and returns a fixed set so `--skills` resolution is
/// deterministic and machine-independent.
class _FakeSkillIntrospector implements SkillIntrospector {
  final Set<String> available;
  final Object? throwOnProbe;
  int calls = 0;

  _FakeSkillIntrospector(this.available, {this.throwOnProbe});

  @override
  Future<Set<String>> listAvailable({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  }) async {
    calls++;
    if (throwOnProbe != null) throw throwOnProbe!;
    return available;
  }
}

const _skillStepYaml = '''
name: skill-workflow
description: Workflow with a skill step.
steps:
  - id: review
    name: Review
    skill: andthen:reveiw
    provider: claude
''';

const _validYaml = '''
name: test-workflow
description: A valid test workflow.
steps:
  - id: step1
    name: Step 1
    prompt: Do the thing.
''';

const _warningsOnlyYaml = '''
name: warning-workflow
description: Workflow with a soft validation warning.
steps:
  - id: work
    name: Work
    prompt: Do the thing.
  - id: approval-loop
    name: Approval Loop
    type: loop
    maxIterations: 3
    exitGate: "work.done == true"
    steps:
      - id: gate
        name: Gate
        type: approval
        prompt: Approve to continue.
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

    test('--skills: unresolvable skill ref warns naming step id, skill, and provider', () async {
      final introspector = _FakeSkillIntrospector({'andthen:review', 'andthen:spec'});
      final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
      final skillCommand = WorkflowValidateCommand(config: config, writeLine: output.add, introspector: introspector);
      final skillRunner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(skillCommand);
      final path = writeFixture('skill.yaml', _skillStepYaml);

      await skillRunner.run(['validate', path, '--skills']);

      final joined = output.join('\n');
      expect(exitCode, 0, reason: 'skill warnings are advisory, never INVALID');
      expect(introspector.calls, 1);
      expect(joined, contains('Skill warnings'));
      expect(joined, contains('step=review'));
      expect(joined, contains('andthen:reveiw'));
      expect(joined, contains('provider "claude"'));
      expect(joined, contains('Result: OK with warnings'));
    });

    test('without --skills: no probe is invoked and a resolvable-skill workflow stays clean', () async {
      final introspector = _FakeSkillIntrospector({'andthen:review'});
      final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
      final skillCommand = WorkflowValidateCommand(config: config, writeLine: output.add, introspector: introspector);
      final skillRunner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(skillCommand);
      final path = writeFixture('skill.yaml', _skillStepYaml);

      await skillRunner.run(['validate', path]);

      final joined = output.join('\n');
      expect(introspector.calls, 0, reason: 'probe must only run under --skills');
      expect(joined, isNot(contains('Skill warnings')));
    });

    test('--skills: probe failure degrades to a note, never a hard failure', () async {
      final introspector = _FakeSkillIntrospector(const {}, throwOnProbe: const ProcessException('claude', []));
      final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
      final skillCommand = WorkflowValidateCommand(config: config, writeLine: output.add, introspector: introspector);
      final skillRunner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(skillCommand);
      final path = writeFixture('skill.yaml', _skillStepYaml);

      await skillRunner.run(['validate', path, '--skills']);

      final joined = output.join('\n');
      expect(exitCode, 0, reason: 'a failed probe must not fail validation');
      expect(joined, contains('Skill resolution not checked'));
      expect(joined, isNot(contains('Skill warnings')));
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
  - id: work
    name: Work
    prompt: Do the thing.
  - id: approval-loop
    name: Approval Loop
    type: loop
    maxIterations: 3
    exitGate: "work.done == true"
    steps:
      - id: loop-gate
        name: Loop Gate
        type: approval
        prompt: Approve to continue.
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
