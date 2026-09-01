import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_list_command.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show AssetResolver;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String templatesDir;
  late String staticDir;
  const sharedAssetResolver = AssetResolver();

  // Absolute: the `ServerConfig` defaults are repo-root-relative, and sibling
  // suites in this package set the process-wide `Directory.current`, which would
  // otherwise flip `AssetResolver` between source-tree and embedded assets.
  setUpAll(() async {
    final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
    if (uri == null) {
      throw StateError('Could not resolve package:dartclaw_runtime.');
    }
    final srcDir = p.join(File.fromUri(uri).parent.path, 'src');
    templatesDir = p.join(srcDir, 'templates');
    staticDir = p.join(srcDir, 'static');
  });

  group('WorkflowListCommand', () {
    late List<String> output;
    late WorkflowListCommand command;
    late CommandRunner<void> runner;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_list_command_test_');
      output = <String>[];
      final config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path, templatesDir: templatesDir, staticDir: staticDir),
      );
      command = WorkflowListCommand(config: config, assetResolver: sharedAssetResolver, writeLine: output.add);
      runner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(command);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
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
