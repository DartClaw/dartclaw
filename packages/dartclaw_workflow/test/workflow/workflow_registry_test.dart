import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinitionParser, WorkflowDefinitionValidator, WorkflowRegistry, WorkflowSource;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

WorkflowRegistry _makeRegistry() =>
    WorkflowRegistry(parser: WorkflowDefinitionParser(), validator: WorkflowDefinitionValidator());

/// A minimal valid workflow YAML for testing custom loading.
String _validCustomYaml(String name) =>
    '''
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

/// Valid YAML with a warning-only validation issue (unknown step type).
/// This should load successfully with a warning but not be excluded.
String _warningsOnlyYaml(String name) =>
    '''
name: $name
description: Workflow with a future step type.
steps:
  - id: step1
    name: Step 1
    type: future-type
    prompt: Do the thing.
''';

/// Valid YAML with a hard error (approval step as parallel — always an error).
const _approvalParallelErrorYaml = '''
name: approval-parallel-error
description: Workflow with parallel approval step.
steps:
  - id: gate
    name: Gate
    type: approval
    parallel: true
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
    test('populates registry with 4 built-in workflows', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.length, equals(4));
    });

    test('listBuiltIn() returns only built-in definitions', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.listBuiltIn(), hasLength(4));
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

    test('listAll() returns all built-in definitions', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      expect(registry.listAll(), hasLength(4));
    });

    test('listSummaries() returns summary records without full step payloads', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();

      final summaries = registry.listSummaries();
      expect(summaries, hasLength(4));
      final summary = summaries.firstWhere((entry) => entry.name == 'code-review');
      expect(summary.description, isNotEmpty);
      expect(summary.stepCount, greaterThan(0));
      expect(summary.variables.containsKey('TARGET'), isTrue);
    });

    test('loads all expected built-in workflow names', () {
      final registry = _makeRegistry();
      registry.loadBuiltIn();
      final names = registry.listAll().map((d) => d.name).toSet();
      expect(names, containsAll(['spec-and-implement', 'plan-and-implement', 'code-review', 'research-and-evaluate']));
    });
  });

  // ------------------------------------------------------------------
  // Custom discovery
  // ------------------------------------------------------------------
  group('loadFromDirectory()', () {
    test('valid custom .yaml is loaded and available via getByName()', () async {
      File(p.join(tempDir.path, 'my-workflow.yaml')).writeAsStringSync(_validCustomYaml('my-workflow'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('my-workflow'), isNotNull);
    });

    test('listCustom() returns custom definitions', () async {
      File(p.join(tempDir.path, 'custom.yaml')).writeAsStringSync(_validCustomYaml('custom'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.listCustom(), hasLength(1));
      expect(registry.listCustom().first.name, equals('custom'));
    });

    test('sourceOf(customName) returns WorkflowSource.custom', () async {
      File(p.join(tempDir.path, 'my-custom.yaml')).writeAsStringSync(_validCustomYaml('my-custom'));

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
      expect(() => registry.loadFromDirectory(p.join(tempDir.path, 'nonexistent')), returnsNormally);
      await registry.loadFromDirectory(p.join(tempDir.path, 'nonexistent'));
      expect(registry.length, equals(0));
    });

    test('.txt files are ignored', () async {
      File(p.join(tempDir.path, 'workflow.txt')).writeAsStringSync(_validCustomYaml('text-file'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.length, equals(0));
    });

    test('subdirectories are not traversed (non-recursive)', () async {
      final subdir = Directory(p.join(tempDir.path, 'subdir'))..createSync();
      File(p.join(subdir.path, 'nested.yaml')).writeAsStringSync(_validCustomYaml('nested'));

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
      File(p.join(tempDir.path, 'bad-syntax.yaml')).writeAsStringSync(_invalidYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.length, equals(0));
    });

    test('schema validation failure: workflow excluded, no exception', () async {
      File(p.join(tempDir.path, 'bad-schema.yaml')).writeAsStringSync(_invalidSchemaYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.length, equals(0));
    });

    test('mix of valid and invalid: valid loaded, invalid excluded', () async {
      File(p.join(tempDir.path, 'valid.yaml')).writeAsStringSync(_validCustomYaml('valid-wf'));
      File(p.join(tempDir.path, 'bad.yaml')).writeAsStringSync(_invalidYaml);

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
      File(p.join(tempDir.path, 'spec-and-implement.yaml')).writeAsStringSync(_validCustomYaml('spec-and-implement'));

      final registry = _makeRegistry();
      registry.loadBuiltIn();
      await registry.loadFromDirectory(tempDir.path);

      // Still built-in
      expect(registry.sourceOf('spec-and-implement'), equals(WorkflowSource.builtIn));
      // Total count unchanged — custom did not add a new entry
      expect(registry.length, equals(4));
    });

    test('two custom workflows with same name: last loaded wins', () async {
      final dir1 = Directory(p.join(tempDir.path, 'dir1'))..createSync();
      final dir2 = Directory(p.join(tempDir.path, 'dir2'))..createSync();
      File(p.join(dir1.path, 'wf.yaml')).writeAsStringSync(_validCustomYaml('my-wf'));
      File(p.join(dir2.path, 'wf.yaml')).writeAsStringSync(_validCustomYaml('my-wf'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(dir1.path);
      await registry.loadFromDirectory(dir2.path);

      // Loaded, last-wins — only 1 entry with the name
      expect(registry.getByName('my-wf'), isNotNull);
      expect(registry.length, equals(1));
    });

    test('custom with unique name alongside built-ins: both available', () async {
      File(p.join(tempDir.path, 'unique-wf.yaml')).writeAsStringSync(_validCustomYaml('unique-wf'));

      final registry = _makeRegistry();
      registry.loadBuiltIn();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('unique-wf'), isNotNull);
      expect(registry.getByName('spec-and-implement'), isNotNull);
      expect(registry.length, equals(5));
    });
  });

  // ------------------------------------------------------------------
  // Integration: built-in + custom combined
  // ------------------------------------------------------------------
  group('integration: built-in + custom', () {
    test('listAll() includes both built-in and custom definitions', () async {
      File(p.join(tempDir.path, 'custom-a.yaml')).writeAsStringSync(_validCustomYaml('custom-a'));
      File(p.join(tempDir.path, 'custom-b.yaml')).writeAsStringSync(_validCustomYaml('custom-b'));
      File(p.join(tempDir.path, 'broken.yaml')).writeAsStringSync(_invalidYaml);

      final registry = _makeRegistry();
      registry.loadBuiltIn();
      await registry.loadFromDirectory(tempDir.path);

      // 4 built-in + 2 valid custom (broken excluded)
      expect(registry.length, equals(6));
      expect(registry.listBuiltIn(), hasLength(4));
      expect(registry.listCustom(), hasLength(2));
      expect(registry.listAll(), hasLength(6));
    });
  });

  // ------------------------------------------------------------------
  // S01 (0.16.1): warnings-only and hard-error registry behavior
  // ------------------------------------------------------------------
  group('S01 (0.16.1): warnings-only loading', () {
    test('warnings-only custom workflow is registered and listable', () async {
      File(p.join(tempDir.path, 'warn-wf.yaml')).writeAsStringSync(_warningsOnlyYaml('warn-wf'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      // Warnings-only definition should still be registered.
      expect(registry.getByName('warn-wf'), isNotNull);
      expect(registry.listCustom(), hasLength(1));
    });

    test('hard-error workflow is excluded even if warnings also present', () async {
      File(p.join(tempDir.path, 'error-wf.yaml')).writeAsStringSync(_approvalParallelErrorYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      // Error-only definition must be excluded.
      expect(registry.getByName('approval-parallel-error'), isNull);
      expect(registry.length, equals(0));
    });

    test('warnings-only workflow and erroring workflow: only warnings-only loads', () async {
      File(p.join(tempDir.path, 'warn-wf.yaml')).writeAsStringSync(_warningsOnlyYaml('warn-wf'));
      File(p.join(tempDir.path, 'error-wf.yaml')).writeAsStringSync(_approvalParallelErrorYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('warn-wf'), isNotNull);
      expect(registry.getByName('approval-parallel-error'), isNull);
      expect(registry.length, equals(1));
    });
  });

  // ------------------------------------------------------------------
  // S01 (0.16.1): TI06 continuity-provider capability flow
  // ------------------------------------------------------------------
  group('S01 (0.16.1): continuity-provider capability validation', () {
    const continueSessionYaml = '''
name: continue-session-wf
description: Workflow using continueSession.
steps:
  - id: s1
    name: Step 1
    prompt: Do research.
  - id: s2
    name: Step 2
    prompt: Follow up.
    continueSession: true
    provider: claude
''';

    test('continueSession fixture excluded when provider set excludes the provider', () async {
      File(p.join(tempDir.path, 'cont-wf.yaml')).writeAsStringSync(continueSessionYaml);

      // Registry with empty continuityProviders set — claude not supported.
      final registry = WorkflowRegistry(
        parser: WorkflowDefinitionParser(),
        validator: WorkflowDefinitionValidator(),
        continuityProviders: const {},
      );
      await registry.loadFromDirectory(tempDir.path);

      // Should be excluded because claude not in continuityProviders.
      expect(registry.getByName('continue-session-wf'), isNull);
    });

    test('continueSession fixture passes when provider set includes the provider', () async {
      File(p.join(tempDir.path, 'cont-wf.yaml')).writeAsStringSync(continueSessionYaml);

      // Registry with claude in continuityProviders — supported.
      final registry = WorkflowRegistry(
        parser: WorkflowDefinitionParser(),
        validator: WorkflowDefinitionValidator(),
        continuityProviders: const {'claude'},
      );
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('continue-session-wf'), isNotNull);
    });
  });
}
