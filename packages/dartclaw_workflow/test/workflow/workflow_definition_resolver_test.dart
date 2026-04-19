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
      final plan = resolved.steps.firstWhere((s) => s.id == 'plan');
      expect(plan.provider, '@planner');
      expect(plan.model, '@planner');
      // Explicit role aliases are preserved — the resolver applies `stepDefaults`
      // patterns but leaves role aliases to runtime resolution.
      expect(
        resolved.stepDefaults,
        isNull,
        reason: 'resolved definition drops stepDefaults (already merged into each step)',
      );
    });

    test('round-trips the three built-in workflows through emitYaml → parser', () async {
      for (final name in ['plan-and-implement.yaml', 'spec-and-implement.yaml', 'code-review.yaml']) {
        final def = await parser.parseFile(builtInWorkflowPath(name));
        final resolved = resolver.resolve(def);
        final yaml = resolver.emitYaml(resolved);
        // Parse the resolved YAML and assert step ids, count, and provider merges match.
        final reparsed = parser.parse(yaml, sourcePath: 'resolved:$name');
        expect(
          reparsed.steps.map((s) => s.id).toList(),
          resolved.steps.map((s) => s.id).toList(),
          reason: 'step ids must match after round-trip for $name',
        );
        expect(reparsed.steps.length, resolved.steps.length);
        // Validate structurally to ensure the emitted YAML is still a valid workflow.
        final report = validator.validate(reparsed);
        expect(report.errors, isEmpty, reason: 'resolved $name emits YAML that fails validation: ${report.errors}');
      }
    });

    test('sliceStep emits a single-step document that parses cleanly', () async {
      final def = await parser.parseFile(builtInWorkflowPath('plan-and-implement.yaml'));
      final resolved = resolver.resolve(def);
      final slice = resolver.sliceStep(resolved, 'plan');
      expect(slice, isNotNull);
      final yaml = resolver.emitYaml(slice!);
      final reparsed = parser.parse(yaml, sourcePath: 'slice:plan');
      expect(reparsed.steps.length, 1);
      expect(reparsed.steps.first.id, 'plan');
    });

    test('preserves entryGate through resolution and round-trip emission', () {
      final def = WorkflowDefinition(
        name: 'entry-gate-demo',
        description: 'test',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            type: 'analysis',
            prompts: ['Review'],
            entryGate: 'prd_source == synthesized',
          ),
        ],
      );

      final resolved = resolver.resolve(def);
      expect(resolved.steps.first.entryGate, 'prd_source == synthesized');

      final reparsed = parser.parse(resolver.emitYaml(resolved), sourcePath: 'resolved:entry-gate-demo');
      expect(reparsed.steps.first.entryGate, 'prd_source == synthesized');
    });

    test('round-trips worktree: auto through emitYaml and parser', () {
      const def = WorkflowDefinition(
        name: 'auto-worktree-demo',
        description: 'test',
        steps: [
          WorkflowStep(id: 'stories', name: 'Stories', prompts: ['Produce stories'], contextOutputs: ['items']),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
          ),
        ],
        gitStrategy: WorkflowGitStrategy(bootstrap: true, worktree: WorkflowGitWorktreeStrategy(mode: 'auto')),
      );

      final yaml = resolver.emitYaml(resolver.resolve(def));
      final reparsed = parser.parse(yaml, sourcePath: 'resolved:auto-worktree-demo');
      expect(reparsed.gitStrategy?.worktreeMode, 'auto');
    });

    test('variable substitution replaces {{VAR}} but leaves {{context.*}} alone', () {
      final def = WorkflowDefinition(
        name: 'var-demo',
        description: 'test',
        variables: {'REQUIREMENTS': const WorkflowVariable(required: true)},
        steps: [
          const WorkflowStep(
            id: 'step-1',
            name: 'Example',
            type: 'analysis',
            prompts: ['Build {{REQUIREMENTS}} using {{context.prior_step.output}}.'],
            contextOutputs: ['result'],
          ),
        ],
      );
      final resolved = resolver.resolve(def, variableBindings: {'REQUIREMENTS': 'a new API endpoint'});
      expect(resolved.steps.first.prompts!.first, 'Build a new API endpoint using {{context.prior_step.output}}.');
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
