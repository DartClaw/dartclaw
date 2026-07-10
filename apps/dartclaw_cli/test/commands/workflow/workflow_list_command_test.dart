import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_list_command.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, ServerConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  const sharedAssetResolver = AssetResolver();

  group('WorkflowListCommand', () {
    late List<String> output;
    late WorkflowListCommand command;
    late CommandRunner<void> runner;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_list_command_test_');
      output = <String>[];
      final config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path));
      command = WorkflowListCommand(config: config, assetResolver: sharedAssetResolver, writeLine: output.add);
      runner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(command);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
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

    test('accepts --standalone for workflow command parity', () {
      expect(command.argParser.options.containsKey('standalone'), isTrue);
    });

    test('default output is tabular with materialized workflows', () async {
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
      expect(joined, contains('materialized'));
    });

    test('human output names each workflow\'s required variables', () async {
      await runner.run(['list']);

      final joined = output.join('\n');
      expect(joined, contains('VARIABLES'));
      // plan-and-implement declares FEATURE as required.
      expect(joined, contains('FEATURE'));
    });

    test('--json output is unchanged by the human variables column', () async {
      await runner.run(['list', '--json']);

      // The human-only column must not leak into the machine output.
      expect(output.first, isNot(contains('VARIABLES')));
      final decoded = jsonDecode(output.first) as List<dynamic>;
      final planEntry = decoded.cast<Map<String, dynamic>>().firstWhere(
        (e) => e['name'] == 'plan-and-implement',
        orElse: () => <String, dynamic>{},
      );
      expect((planEntry['variables'] as Map?)?.containsKey('FEATURE'), isTrue);
    });

    test('json output is valid JSON array', () async {
      await runner.run(['list', '--json']);

      expect(output, hasLength(1));
      final decoded = output.first;
      // Should be parseable JSON array
      expect(decoded.trim(), startsWith('['));
      expect(decoded.trim(), endsWith(']'));
      final list = jsonDecode(decoded) as List<dynamic>;
      expect(list.first['source'], 'materialized');
    });

    test('json output contains workflow fields', () async {
      await runner.run(['list', '--json']);

      expect(output, hasLength(1));
      expect(output.first, contains('"name"'));
      expect(output.first, contains('"description"'));
      expect(output.first, contains('"stepCount"'));
      expect(output.first, contains('"source"'));
    });

    test('summary line shows materialized count', () async {
      await runner.run(['list']);

      final totalLine = output.lastWhere((l) => l.contains('Total:'));
      expect(totalLine, contains('materialized'));
    });

    test('lists custom workflows from the canonical data-dir workflows custom folder', () async {
      final workflowsDir = Directory(p.join(tempDir.path, 'workflows', 'custom'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'my-review.yaml')).writeAsStringSync('''
name: my-review
description: Canonical custom workflow
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'ok\\n'
''');

      await runner.run(['list', '--standalone']);

      expect(output.join('\n'), contains('my-review'));
    });

    test('lists legacy custom workflows placed directly under data-dir workflows', () async {
      final workflowsDir = Directory(p.join(tempDir.path, 'workflows'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'my-review.yaml')).writeAsStringSync('''
name: my-review
description: Direct data-dir workflow
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'ok\\n'
''');

      await runner.run(['list', '--standalone']);

      expect(output.join('\n'), contains('my-review'));
    });

    test('uses embedded workflows when no installed assets exist', () async {
      final installedOutput = <String>[];
      final installedCommand = WorkflowListCommand(
        config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
        assetResolver: sharedAssetResolver,
        writeLine: installedOutput.add,
      );
      final installedRunner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(installedCommand);

      await installedRunner.run(['list']);

      final joined = installedOutput.join('\n');
      expect(joined, contains('code-review'));
      expect(joined, contains('materialized'));
    });
  });
}
