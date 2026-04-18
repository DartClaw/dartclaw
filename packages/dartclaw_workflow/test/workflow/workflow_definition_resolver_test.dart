import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowDefinitionResolver', () {
    late WorkflowDefinitionParser parser;
    late WorkflowDefinitionResolver resolver;
    late WorkflowDefinitionValidator validator;

    setUp(() {
      parser = WorkflowDefinitionParser();
      resolver = const WorkflowDefinitionResolver();
      validator = WorkflowDefinitionValidator();
    });

    test('applies stepDefaults pattern to steps without explicit provider/model', () async {
      final def = await parser.parseFile(builtInWorkflowPath('plan-and-implement.yaml'));
      final resolved = resolver.resolve(def);
      final reviewPrd = resolved.steps.firstWhere((s) => s.id == 'review-prd');
      expect(reviewPrd.provider, '@reviewer');
      expect(reviewPrd.model, '@reviewer');
      // Explicit role aliases are preserved — the resolver applies `stepDefaults`
      // patterns but leaves role aliases to runtime resolution.
      expect(resolved.stepDefaults, isNull,
          reason: 'resolved definition drops stepDefaults (already merged into each step)');
    });

    test('round-trips the three built-in workflows through emitYaml → parser', () async {
      for (final name in ['plan-and-implement.yaml', 'spec-and-implement.yaml', 'code-review.yaml']) {
        final def = await parser.parseFile(builtInWorkflowPath(name));
        final resolved = resolver.resolve(def);
        final yaml = resolver.emitYaml(resolved);
        // Parse the resolved YAML and assert step ids, count, and provider merges match.
        final reparsed = parser.parse(yaml, sourcePath: 'resolved:$name');
        expect(reparsed.steps.map((s) => s.id).toList(), resolved.steps.map((s) => s.id).toList(),
            reason: 'step ids must match after round-trip for $name');
        expect(reparsed.steps.length, resolved.steps.length);
        // Validate structurally to ensure the emitted YAML is still a valid workflow.
        final report = validator.validate(reparsed);
        expect(
          report.errors,
          isEmpty,
          reason: 'resolved $name emits YAML that fails validation: ${report.errors}',
        );
      }
    });

    test('sliceStep emits a single-step document that parses cleanly', () async {
      final def = await parser.parseFile(builtInWorkflowPath('plan-and-implement.yaml'));
      final resolved = resolver.resolve(def);
      final slice = resolver.sliceStep(resolved, 'review-prd');
      expect(slice, isNotNull);
      final yaml = resolver.emitYaml(slice!);
      final reparsed = parser.parse(yaml, sourcePath: 'slice:review-prd');
      expect(reparsed.steps.length, 1);
      expect(reparsed.steps.first.id, 'review-prd');
    });

    test('variable substitution replaces {{VAR}} but leaves {{context.*}} alone', () {
      final def = WorkflowDefinition(
        name: 'var-demo',
        description: 'test',
        variables: {
          'REQUIREMENTS': const WorkflowVariable(required: true),
        },
        steps: [
          const WorkflowStep(
            id: 'step-1',
            name: 'Example',
            type: 'analysis',
            prompts: [
              'Build {{REQUIREMENTS}} using {{context.prior_step.output}}.',
            ],
            contextOutputs: ['result'],
          ),
        ],
      );
      final resolved =
          resolver.resolve(def, variableBindings: {'REQUIREMENTS': 'a new API endpoint'});
      expect(
        resolved.steps.first.prompts!.first,
        'Build a new API endpoint using {{context.prior_step.output}}.',
      );
    });
  });
}

String builtInWorkflowPath(String fileName) {
  // Tests may run with either the package root or the workspace root as CWD.
  // Probe both so the test is portable across `dart test packages/...` and
  // package-local invocations.
  const relative = 'lib/src/workflow/definitions';
  const packaged = 'packages/dartclaw_workflow/$relative';
  for (final candidate in ['$relative/$fileName', '$packaged/$fileName']) {
    if (File(candidate).existsSync()) return candidate;
  }
  return '$relative/$fileName';
}
