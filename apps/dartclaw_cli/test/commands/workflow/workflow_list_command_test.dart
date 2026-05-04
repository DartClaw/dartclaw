import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_list_command.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, ServerConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Resolved via package URI in setUpAll. This avoids depending on
// Directory.current (mutated concurrently by sibling test files) or
// Platform.script (synthetic in test runner mode), both of which made
// the upward filesystem walk flaky under default-concurrency runs.
Future<String> _resolveBuiltInWorkflowDefinitionsDir() async {
  final uri = await Isolate.resolvePackageUri(
    Uri.parse('package:dartclaw_workflow/src/workflow/definitions/code-review.yaml'),
  );
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_workflow definitions dir via package URI');
  }
  return p.dirname(uri.toFilePath());
}

void main() {
  late Directory tempDir;
  // Shared mock asset root populated once. Lets WorkflowListCommand resolve
  // the built-in workflow source via AssetResolver instead of walking up
  // from Directory.current — which is unsafe during parallel test runs.
  late Directory sharedAssetTempDir;
  late AssetResolver sharedAssetResolver;

  group('WorkflowListCommand', () {
    late List<String> output;
    late WorkflowListCommand command;
    late CommandRunner<void> runner;

    setUpAll(() async {
      final builtInDefinitionsDir = await _resolveBuiltInWorkflowDefinitionsDir();
      sharedAssetTempDir = Directory.systemTemp.createTempSync('workflow_list_assets_');
      final assetRoot = Directory(p.join(sharedAssetTempDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
      Directory(p.join(assetRoot.path, 'templates')).createSync(recursive: true);
      Directory(p.join(assetRoot.path, 'static')).createSync(recursive: true);
      final workflowsDir = Directory(p.join(assetRoot.path, 'workflows'))..createSync(recursive: true);
      for (final entity in Directory(builtInDefinitionsDir).listSync(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.yaml')) {
          entity.copySync(p.join(workflowsDir.path, p.basename(entity.path)));
        }
      }
      sharedAssetResolver = AssetResolver(resolvedExecutable: p.join(sharedAssetTempDir.path, 'bin', 'dartclaw'));
    });

    tearDownAll(() {
      if (sharedAssetTempDir.existsSync()) {
        sharedAssetTempDir.deleteSync(recursive: true);
      }
    });

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

    test('uses installed assets when available', () async {
      final assetRoot = Directory(p.join(tempDir.path, 'share', 'dartclaw'))..createSync(recursive: true);
      Directory(p.join(assetRoot.path, 'templates')).createSync(recursive: true);
      Directory(p.join(assetRoot.path, 'static')).createSync(recursive: true);
      final workflowsDir = Directory(p.join(assetRoot.path, 'workflows'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'installed-workflow.yaml')).writeAsStringSync('''
name: installed-workflow
description: Installed workflow for testing.
steps:
  - id: step1
    name: Step 1
    prompt: Do the thing.
''');

      final installedResolver = AssetResolver(resolvedExecutable: p.join(tempDir.path, 'bin', 'dartclaw'));
      final installedOutput = <String>[];
      final installedCommand = WorkflowListCommand(
        config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
        assetResolver: installedResolver,
        writeLine: installedOutput.add,
      );
      final installedRunner = CommandRunner<void>('dartclaw', 'DartClaw CLI')..addCommand(installedCommand);

      await installedRunner.run(['list']);

      final joined = installedOutput.join('\n');
      expect(joined, contains('installed-workflow'));
      expect(joined, contains('materialized'));
    });
  });
}
