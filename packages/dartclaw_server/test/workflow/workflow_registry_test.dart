import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show WorkflowDefinitionParser, WorkflowDefinitionValidator;
import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowRegistry, WorkflowSource;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

WorkflowRegistry _makeRegistry() => WorkflowRegistry(
  parser: WorkflowDefinitionParser(),
  validator: WorkflowDefinitionValidator(),
);

/// A minimal valid workflow YAML for testing custom loading.
String _validCustomYaml(String name) => '''
name: $name
description: Custom workflow for testing.
steps:
  - id: step1
    name: Step 1
    prompt: Do the thing.
''';

/// Invalid YAML (syntax error).
const _invalidYaml = 'name: : bad: yaml: {{{{';

/// Valid YAML but fails schema validation (empty steps list not representable
/// in YAML, so we use missing required 'description' field instead).
const _invalidSchemaYaml = '''
name: missing-description
steps:
  - id: step1
    name: Step 1
    prompt: Do the thing.
''';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_registry_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ------------------------------------------------------------------
  // Built-in loading
  // ------------------------------------------------------------------
  group('loadBuiltIn()', () {
    test('populates registry with 6 built-in workflows', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.length, equals(6));
    });

    test('listBuiltIn() returns only built-in definitions', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.listBuiltIn(), hasLength(6));
    });

    test('listCustom() is empty after loadBuiltIn() only', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.listCustom(), isEmpty);
    });

    test('getByName("spec-and-implement") returns the definition', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      final def = registry.getByName('spec-and-implement');
      expect(def, isNotNull);
      expect(def!.name, equals('spec-and-implement'));
    });

    test('getByName("nonexistent") returns null', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.getByName('nonexistent'), isNull);
    });

    test('sourceOf("spec-and-implement") returns WorkflowSource.builtIn', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.sourceOf('spec-and-implement'), equals(WorkflowSource.builtIn));
    });

    test('listAll() returns all 6 built-in definitions', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.listAll(), hasLength(6));
    });

    test('loads all expected built-in workflow names', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      final names = registry.listAll().map((d) => d.name).toSet();
      expect(
        names,
        containsAll([
          'spec-and-implement',
          'research-and-evaluate',
          'fix-bug',
          'refactor',
          'review-and-remediate',
          'plan-and-execute',
        ]),
      );
    });
  });

  // ------------------------------------------------------------------
  // Custom discovery
  // ------------------------------------------------------------------
  group('loadFromDirectory()', () {
    test('valid custom .yaml is loaded and available via getByName()', () async {
      File(p.join(tempDir.path, 'my-workflow.yaml'))
          .writeAsStringSync(_validCustomYaml('my-workflow'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('my-workflow'), isNotNull);
    });

    test('listCustom() returns custom definitions', () async {
      File(p.join(tempDir.path, 'custom.yaml'))
          .writeAsStringSync(_validCustomYaml('custom'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.listCustom(), hasLength(1));
      expect(registry.listCustom().first.name, equals('custom'));
    });

    test('sourceOf(customName) returns WorkflowSource.custom', () async {
      File(p.join(tempDir.path, 'my-custom.yaml'))
          .writeAsStringSync(_validCustomYaml('my-custom'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.sourceOf('my-custom'), equals(WorkflowSource.custom));
    });

    test('directory with no .yaml files results in no custom workflows', () async {
      File(p.join(tempDir.path, 'readme.txt')).writeAsStringSync('hello');

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.listCustom(), isEmpty);
    });

    test('non-existent directory is silently skipped (no error)', () async {
      final registry = _makeRegistry();
      expect(
        () => registry.loadFromDirectory(p.join(tempDir.path, 'nonexistent')),
        returnsNormally,
      );
      await registry.loadFromDirectory(p.join(tempDir.path, 'nonexistent'));
      expect(registry.length, equals(0));
    });

    test('.txt files are ignored', () async {
      File(p.join(tempDir.path, 'workflow.txt'))
          .writeAsStringSync(_validCustomYaml('text-file'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.length, equals(0));
    });

    test('subdirectories are not traversed (non-recursive)', () async {
      final subdir = Directory(p.join(tempDir.path, 'subdir'))
        ..createSync();
      File(p.join(subdir.path, 'nested.yaml'))
          .writeAsStringSync(_validCustomYaml('nested'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('nested'), isNull);
    });
  });

  // ------------------------------------------------------------------
  // Validation and error handling
  // ------------------------------------------------------------------
  group('validation and error handling', () {
    test('invalid YAML syntax: workflow excluded, no exception', () async {
      File(p.join(tempDir.path, 'bad-syntax.yaml'))
          .writeAsStringSync(_invalidYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.length, equals(0));
    });

    test('schema validation failure: workflow excluded, no exception', () async {
      File(p.join(tempDir.path, 'bad-schema.yaml'))
          .writeAsStringSync(_invalidSchemaYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.length, equals(0));
    });

    test('mix of valid and invalid: valid loaded, invalid excluded', () async {
      File(p.join(tempDir.path, 'valid.yaml'))
          .writeAsStringSync(_validCustomYaml('valid-wf'));
      File(p.join(tempDir.path, 'bad.yaml'))
          .writeAsStringSync(_invalidYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.length, equals(1));
      expect(registry.getByName('valid-wf'), isNotNull);
    });
  });

  // ------------------------------------------------------------------
  // Name collision
  // ------------------------------------------------------------------
  group('name collision', () {
    test('custom with built-in name: built-in kept, custom skipped', () async {
      File(p.join(tempDir.path, 'spec-and-implement.yaml'))
          .writeAsStringSync(_validCustomYaml('spec-and-implement'));

      final registry = _makeRegistry();
      registry.loadBuiltIn();
      await registry.loadFromDirectory(tempDir.path);

      // Still built-in
      expect(registry.sourceOf('spec-and-implement'), equals(WorkflowSource.builtIn));
      // Total count unchanged — custom did not add a new entry
      expect(registry.length, equals(6));
    });

    test('two custom workflows with same name: last loaded wins', () async {
      final dir1 = Directory(p.join(tempDir.path, 'dir1'))..createSync();
      final dir2 = Directory(p.join(tempDir.path, 'dir2'))..createSync();
      File(p.join(dir1.path, 'wf.yaml'))
          .writeAsStringSync(_validCustomYaml('my-wf'));
      File(p.join(dir2.path, 'wf.yaml'))
          .writeAsStringSync(_validCustomYaml('my-wf'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(dir1.path);
      await registry.loadFromDirectory(dir2.path);

      // Loaded, last-wins — only 1 entry with the name
      expect(registry.getByName('my-wf'), isNotNull);
      expect(registry.length, equals(1));
    });

    test('custom with unique name alongside built-ins: both available', () async {
      File(p.join(tempDir.path, 'unique-wf.yaml'))
          .writeAsStringSync(_validCustomYaml('unique-wf'));

      final registry = _makeRegistry();
      registry.loadBuiltIn();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('unique-wf'), isNotNull);
      expect(registry.getByName('spec-and-implement'), isNotNull);
      expect(registry.length, equals(7));
    });
  });

  // ------------------------------------------------------------------
  // Integration: built-in + custom combined
  // ------------------------------------------------------------------
  group('integration: built-in + custom', () {
    test('listAll() includes both built-in and custom definitions', () async {
      File(p.join(tempDir.path, 'custom-a.yaml'))
          .writeAsStringSync(_validCustomYaml('custom-a'));
      File(p.join(tempDir.path, 'custom-b.yaml'))
          .writeAsStringSync(_validCustomYaml('custom-b'));
      File(p.join(tempDir.path, 'broken.yaml'))
          .writeAsStringSync(_invalidYaml);

      final registry = _makeRegistry();
      registry.loadBuiltIn();
      await registry.loadFromDirectory(tempDir.path);

      // 6 built-in + 2 valid custom (broken excluded)
      expect(registry.length, equals(8));
      expect(registry.listBuiltIn(), hasLength(6));
      expect(registry.listCustom(), hasLength(2));
      expect(registry.listAll(), hasLength(8));
    });
  });
}
