import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowDefinitionParser, WorkflowDefinitionValidator, WorkflowRegistry, WorkflowSource;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

WorkflowRegistry _makeRegistry({Logger? log, Set<String>? continuityProviders}) => WorkflowRegistry(
  parser: WorkflowDefinitionParser(),
  validator: WorkflowDefinitionValidator(),
  continuityProviders: continuityProviders,
  log: log,
);

String _workflowDefinitionsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'lib', 'src', 'workflow', 'definitions'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow definitions dir');
    }
    current = parent;
  }
}

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
  // Materialized loading
  // ------------------------------------------------------------------
  group('materialized loading', () {
    test('populates registry with 3 materialized workflows', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      expect(registry.length, equals(3));
    });

    test('listMaterialized() returns only materialized definitions', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      expect(registry.listMaterialized(), hasLength(3));
    });

    test('listCustom() is empty after materialized loading only', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      expect(registry.listCustom(), isEmpty);
    });

    test('getByName("spec-and-implement") returns the definition', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      final def = registry.getByName('spec-and-implement');
      expect(def, isNotNull);
      expect(def!.name, equals('spec-and-implement'));
    });

    test('bootstrap built-ins leave BRANCH empty so project resolution can infer the base ref', () async {
      final parser = WorkflowDefinitionParser();
      for (final name in ['spec-and-implement.yaml', 'plan-and-implement.yaml']) {
        final definition = await parser.parseFile(p.join(_workflowDefinitionsDir(), name));
        expect(
          definition.variables['BRANCH']?.defaultValue,
          anyOf(isNull, isEmpty),
          reason: '$name should not hardcode main for workflow bootstrap',
        );
      }

      final codeReview = await parser.parseFile(p.join(_workflowDefinitionsDir(), 'code-review.yaml'));
      expect(codeReview.variables['BASE_BRANCH']?.defaultValue, 'main');
    });

    test('getByName("nonexistent") returns null', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      expect(registry.getByName('nonexistent'), isNull);
    });

    test('sourceOf("spec-and-implement") returns WorkflowSource.materialized', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      expect(registry.sourceOf('spec-and-implement'), equals(WorkflowSource.materialized));
    });

    test('listAll() returns all materialized definitions', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      expect(registry.listAll(), hasLength(3));
    });

    test('listSummaries() returns summary records without full step payloads', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);

      final summaries = registry.listSummaries();
      expect(summaries, hasLength(3));
      final summary = summaries.firstWhere((entry) => entry.name == 'code-review');
      expect(summary.description, isNotEmpty);
      expect(summary.stepCount, greaterThan(0));
      expect(summary.variables.containsKey('TARGET'), isTrue);
    });

    test('loads all expected materialized workflow names', () async {
      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      final names = registry.listAll().map((d) => d.name).toSet();
      expect(names, containsAll(['spec-and-implement', 'plan-and-implement', 'code-review']));
    });

    test('materialized workflow YAMLs do not embed runtime budget policy', () async {
      final parser = WorkflowDefinitionParser();
      final definitionsDir = _workflowDefinitionsDir();
      final defs = await Future.wait([
        parser.parseFile(p.join(definitionsDir, 'spec-and-implement.yaml')),
        parser.parseFile(p.join(definitionsDir, 'plan-and-implement.yaml')),
        parser.parseFile(p.join(definitionsDir, 'code-review.yaml')),
      ]);
      for (final def in defs) {
        expect(def.maxTokens, isNull, reason: '${def.name} must not embed a maxTokens budget policy');
      }
    });

    test('built-ins adopt the shared project/branch contract and direct specialist review routing', () async {
      final parser = WorkflowDefinitionParser();
      final definitionsDir = _workflowDefinitionsDir();
      final specAndImplement = await parser.parseFile(p.join(definitionsDir, 'spec-and-implement.yaml'));
      final planAndImplement = await parser.parseFile(p.join(definitionsDir, 'plan-and-implement.yaml'));
      final codeReview = await parser.parseFile(p.join(definitionsDir, 'code-review.yaml'));

      void assertSkills(WorkflowDefinition def, List<String> required, List<String> forbidden) {
        final allSkills = def.steps.map((s) => s.skill).whereType<String>().toSet();
        for (final r in required) {
          expect(allSkills, contains(r), reason: '${def.name} must use skill $r');
        }
        for (final f in forbidden) {
          expect(allSkills, isNot(contains(f)), reason: '${def.name} must not use skill $f');
        }
      }

      // spec-and-implement: BRANCH variable, gitStrategy, revise-spec step, not approve-spec.
      expect(specAndImplement.variables.containsKey('BRANCH'), isTrue);
      expect(specAndImplement.variables.containsKey('BASE_BRANCH'), isFalse);
      expect(specAndImplement.gitStrategy, isNotNull);
      expect(specAndImplement.steps.any((s) => s.id == 'revise-spec'), isTrue);
      expect(specAndImplement.steps.any((s) => s.id == 'approve-spec'), isFalse);
      expect(specAndImplement.steps.any((s) => s.id == 'review-spec'), isFalse);
      // Confidence-gated revise-spec uses entryGate that references spec_confidence.
      final reviseSpec = specAndImplement.steps.firstWhere((s) => s.id == 'revise-spec');
      expect(reviseSpec.entryGate, contains('spec_confidence'));
      // spec_path is referenced somewhere in the definition steps.
      expect(specAndImplement.steps.any((s) => s.prompts?.any((p) => p.contains('spec_path')) ?? false), isTrue);
      assertSkills(specAndImplement, ['dartclaw-review'], ['andthen-review', 'dartclaw-review-gap']);

      // plan-and-implement: BRANCH variable, gitStrategy, revise-prd step, not review-prd.
      expect(planAndImplement.variables.containsKey('BRANCH'), isTrue);
      expect(planAndImplement.gitStrategy, isNotNull);
      expect(planAndImplement.steps.any((s) => s.id == 'revise-prd'), isTrue);
      expect(planAndImplement.steps.any((s) => s.id == 'review-prd'), isFalse);
      final revisePrd = planAndImplement.steps.firstWhere((s) => s.id == 'revise-prd');
      expect(revisePrd.entryGate, contains('prd_confidence'));
      expect(planAndImplement.steps.any((s) => s.id == 'update-state'), isFalse);
      assertSkills(
        planAndImplement,
        ['dartclaw-quick-review', 'dartclaw-review', 'dartclaw-plan', 'dartclaw-prd'],
        ['andthen-quick-review', 'andthen-review', 'andthen-plan', 'andthen-prd', 'dartclaw-spec-plan'],
      );

      // code-review: PROJECT variable (not REPO), gitStrategy, dartclaw-review skill.
      expect(codeReview.variables.containsKey('PROJECT'), isTrue);
      expect(codeReview.variables.containsKey('REPO'), isFalse);
      expect(codeReview.gitStrategy, isNotNull);
      assertSkills(codeReview, ['dartclaw-review'], ['andthen-review', 'dartclaw-review-code']);
    });

    test('code-review uses dartclaw-review and forbids legacy andthen-review', () async {
      final parser = WorkflowDefinitionParser();
      final codeReview = await parser.parseFile(p.join(_workflowDefinitionsDir(), 'code-review.yaml'));

      // Exactly two steps use dartclaw-review (initial review + re-review).
      final reviewSteps = codeReview.steps.where((s) => s.skill == 'dartclaw-review').toList();
      expect(reviewSteps.length, equals(2));
      expect(codeReview.steps.map((s) => s.skill), isNot(contains('andthen-review')));

      // No legacy multi-pass step IDs that pre-date the unified reviewer.
      final stepIds = codeReview.steps.map((s) => s.id).toSet();
      for (final legacy in [
        'extract-diff',
        'gather-context',
        'review-correctness',
        'review-security',
        'review-architecture',
      ]) {
        expect(stepIds, isNot(contains(legacy)));
      }
    });

    test('implementation built-ins gate remediation loops on re-review findings only', () async {
      final parser = WorkflowDefinitionParser();
      final definitionsDir = _workflowDefinitionsDir();
      final specAndImplement = await parser.parseFile(p.join(definitionsDir, 'spec-and-implement.yaml'));
      final planAndImplement = await parser.parseFile(p.join(definitionsDir, 'plan-and-implement.yaml'));
      final codeReview = await parser.parseFile(p.join(definitionsDir, 'code-review.yaml'));

      // No legacy verify-refine step in any built-in.
      for (final def in [specAndImplement, planAndImplement, codeReview]) {
        expect(def.steps.any((s) => s.id == 'verify-refine'), isFalse);
      }

      // spec-and-implement remediation loop: entryGate on integrated-review, exitGate on re-review.
      final specRemLoop = specAndImplement.loops.firstWhere((l) => l.entryGate?.contains('integrated-review') ?? false);
      expect(specRemLoop.entryGate, contains('integrated-review.findings_count > 0'));
      expect(specRemLoop.exitGate, contains('re-review.findings_count == 0'));

      // plan-and-implement remediation loop: entryGate on plan-review.
      final planRemLoop = planAndImplement.loops.firstWhere((l) => l.entryGate?.contains('plan-review') ?? false);
      expect(planRemLoop.entryGate, contains('plan-review.findings_count > 0'));
      expect(planRemLoop.exitGate, contains('re-review.findings_count == 0'));

      // code-review remediation loop: entryGate on review-code.
      final codeRemLoop = codeReview.loops.firstWhere((l) => l.entryGate?.contains('review-code') ?? false);
      expect(codeRemLoop.entryGate, contains('review-code.findings_count > 0'));
      expect(codeRemLoop.exitGate, contains('re-review.findings_count == 0'));
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
    test('custom with materialized name: materialized kept, custom skipped', () async {
      File(p.join(tempDir.path, 'spec-and-implement.yaml')).writeAsStringSync(_validCustomYaml('spec-and-implement'));

      final previousHierarchicalLoggingEnabled = hierarchicalLoggingEnabled;
      hierarchicalLoggingEnabled = true;
      addTearDown(() => hierarchicalLoggingEnabled = previousHierarchicalLoggingEnabled);

      final logger = Logger('workflow-registry-test-conflict')..level = Level.ALL;
      final records = <LogRecord>[];
      final sub = logger.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      final registry = _makeRegistry(log: logger);
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.sourceOf('spec-and-implement'), equals(WorkflowSource.materialized));
      expect(registry.length, equals(3));
      expect(
        records.any(
          (record) => record.level == Level.WARNING && record.message.toLowerCase().contains('materialized workflow'),
        ),
        isTrue,
      );
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

    test('custom with unique name alongside materialized workflows: both available', () async {
      File(p.join(tempDir.path, 'unique-wf.yaml')).writeAsStringSync(_validCustomYaml('unique-wf'));

      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      await registry.loadFromDirectory(tempDir.path);

      expect(registry.getByName('unique-wf'), isNotNull);
      expect(registry.getByName('spec-and-implement'), isNotNull);
      expect(registry.length, equals(4));
    });
  });

  // ------------------------------------------------------------------
  // Integration: materialized + custom combined
  // ------------------------------------------------------------------
  group('integration: materialized + custom', () {
    test('listAll() includes both materialized and custom definitions', () async {
      File(p.join(tempDir.path, 'custom-a.yaml')).writeAsStringSync(_validCustomYaml('custom-a'));
      File(p.join(tempDir.path, 'custom-b.yaml')).writeAsStringSync(_validCustomYaml('custom-b'));
      File(p.join(tempDir.path, 'broken.yaml')).writeAsStringSync(_invalidYaml);

      final registry = _makeRegistry();
      await registry.loadFromDirectory(_workflowDefinitionsDir(), source: WorkflowSource.materialized);
      await registry.loadFromDirectory(tempDir.path);

      // 3 materialized + 2 valid custom (broken excluded)
      expect(registry.length, equals(5));
      expect(registry.listMaterialized(), hasLength(3));
      expect(registry.listCustom(), hasLength(2));
      expect(registry.listAll(), hasLength(5));
    });
  });

  // ------------------------------------------------------------------
  // warnings-only and hard-error registry behavior
  // ------------------------------------------------------------------
  group('warnings-only loading', () {
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
  // TI06 continuity-provider capability flow
  // ------------------------------------------------------------------
  group('continuity-provider capability validation', () {
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
