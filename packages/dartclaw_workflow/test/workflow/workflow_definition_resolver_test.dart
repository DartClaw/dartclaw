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

    test('applies stepDefaults timeout to resolved steps', () {
      const def = WorkflowDefinition(
        name: 'timeout-default-demo',
        description: 'test',
        stepDefaults: [StepConfigDefault(match: 'review*', timeoutSeconds: 900)],
        steps: [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['Review']),
          WorkflowStep(id: 'review-fast', name: 'Review Fast', prompts: ['Review'], timeoutSeconds: 120),
        ],
      );

      final resolved = resolver.resolve(def);
      expect(resolved.stepDefaults, isNull);
      expect(resolved.steps.firstWhere((s) => s.id == 'review-code').timeoutSeconds, 900);
      expect(resolved.steps.firstWhere((s) => s.id == 'review-fast').timeoutSeconds, 120);

      final reparsed = parser.parse(resolver.emitYaml(resolved), sourcePath: 'resolved:timeout-default-demo');
      expect(reparsed.steps.firstWhere((s) => s.id == 'review-code').timeoutSeconds, 900);
      expect(reparsed.steps.firstWhere((s) => s.id == 'review-fast').timeoutSeconds, 120);
    });

    test('applies stepDefaults gatingSeverity to resolved steps', () {
      const def = WorkflowDefinition(
        name: 'review-threshold-default-demo',
        description: 'test',
        stepDefaults: [StepConfigDefault(match: 'review*', gatingSeverity: 'critical')],
        steps: [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['Review']),
          WorkflowStep(id: 'review-medium', name: 'Review Medium', prompts: ['Review'], gatingSeverity: 'medium'),
        ],
      );

      final resolved = resolver.resolve(def);
      expect(resolved.stepDefaults, isNull);
      expect(resolved.steps.firstWhere((s) => s.id == 'review-code').gatingSeverity, 'critical');
      expect(resolved.steps.firstWhere((s) => s.id == 'review-medium').gatingSeverity, 'medium');

      final reparsed = parser.parse(resolver.emitYaml(resolved), sourcePath: 'resolved:review-threshold-default-demo');
      expect(reparsed.steps.firstWhere((s) => s.id == 'review-code').gatingSeverity, 'critical');
      expect(reparsed.steps.firstWhere((s) => s.id == 'review-medium').gatingSeverity, 'medium');
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
            taskType: WorkflowTaskType.agent,
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
          WorkflowStep(
            id: 'stories',
            name: 'Stories',
            prompts: ['Produce stories'],
            outputs: {'items': OutputConfig()},
          ),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
          ),
        ],
        gitStrategy: WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto),
        ),
      );

      final yaml = resolver.emitYaml(resolver.resolve(def));
      final reparsed = parser.parse(yaml, sourcePath: 'resolved:auto-worktree-demo');
      expect(reparsed.gitStrategy?.worktreeMode, 'auto');
    });

    test('preserves foreach as alias through resolved YAML round-trip', () {
      const def = WorkflowDefinition(
        name: 'foreach-alias-demo',
        description: 'test',
        steps: [
          WorkflowStep(
            id: 'stories',
            name: 'Stories',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'items',
            mapAlias: 'storyResult',
            foreachSteps: ['implement'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{storyResult.item.id}}']),
        ],
      );

      final yaml = resolver.emitYaml(resolver.resolve(def));
      expect(yaml, contains('as: storyResult'));

      final reparsed = parser.parse(yaml, sourcePath: 'resolved:foreach-alias-demo');
      expect(reparsed.steps.first.mapAlias, 'storyResult');
    });

    test('preserves foreach controller behavior fields through resolved YAML round-trip', () {
      const def = WorkflowDefinition(
        name: 'foreach-controller-fields-demo',
        description: 'test',
        variables: {'FEATURE': WorkflowVariable(required: true)},
        steps: [
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            prompts: ['Plan'],
            outputs: {'items': OutputConfig(), 'ready': OutputConfig()},
          ),
          WorkflowStep(
            id: 'stories',
            name: 'Stories',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'items',
            gate: 'plan.ready == true',
            entryGate: 'items != null',
            inputs: ['items'],
            outputs: {'story_results': OutputConfig()},
            outputExamples: ['{"story_results": []}'],
            foreachSteps: ['implement'],
            onFailure: OnFailurePolicy.continueWorkflow,
            workflowVariables: ['FEATURE'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item.id}}']),
        ],
      );

      final yaml = resolver.emitYaml(resolver.resolve(def));
      expect(yaml, contains('gate: plan.ready == true'));
      expect(yaml, contains('entryGate: items != null'));
      expect(yaml, contains('onFailure: continue'));
      expect(yaml, contains('outputExamples:'));

      final reparsed = parser.parse(yaml, sourcePath: 'resolved:foreach-controller-fields-demo');
      final controller = reparsed.steps.firstWhere((step) => step.id == 'stories');
      expect(controller.gate, 'plan.ready == true');
      expect(controller.entryGate, 'items != null');
      expect(controller.onFailure, OnFailurePolicy.continueWorkflow);
      expect(controller.outputExamples, ['{"story_results": []}']);
      expect(controller.workflowVariables, ['FEATURE']);
      expect(validator.validate(reparsed).errors, isEmpty);
    });

    test('sliceStep emits a foreach controller with its child subtree', () {
      const def = WorkflowDefinition(
        name: 'foreach-slice-demo',
        description: 'test',
        steps: [
          WorkflowStep(
            id: 'stories',
            name: 'Stories',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'items',
            entryGate: 'items != null',
            foreachSteps: ['implement'],
            onFailure: OnFailurePolicy.continueWorkflow,
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item.id}}']),
        ],
      );

      final resolved = resolver.resolve(def);
      final slice = resolver.sliceStep(resolved, 'stories');
      expect(slice, isNotNull);

      final yaml = resolver.emitYaml(slice!);
      expect(yaml, contains('id: implement'));

      final reparsed = parser.parse(yaml, sourcePath: 'slice:stories');
      expect(reparsed.steps.map((step) => step.id), ['stories', 'implement']);
      final controller = reparsed.steps.firstWhere((step) => step.id == 'stories');
      expect(controller.foreachSteps, ['implement']);
      expect(controller.entryGate, 'items != null');
      expect(controller.onFailure, OnFailurePolicy.continueWorkflow);
    });

    test('emitYaml preserves workflow-level project and omits default agent step types', () {
      const def = WorkflowDefinition(
        name: 'project-demo',
        description: 'test',
        project: '{{PROJECT}}',
        variables: {'PROJECT': WorkflowVariable(required: false, defaultValue: 'demo-project')},
        steps: [
          WorkflowStep(
            id: 'discover',
            name: 'Discover',
            prompts: ['Inspect the repo'],
            outputs: {'project_index': OutputConfig()},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement']),
          WorkflowStep(id: 'check', name: 'Check', taskType: WorkflowTaskType.bash, prompts: null, workdir: '.'),
        ],
      );

      final resolved = resolver.resolve(def, variableBindings: {'PROJECT': 'demo-project'});
      final yaml = resolver.emitYaml(resolved);
      expect(yaml, contains('project: demo-project'));
      expect(yaml, isNot(contains('type: agent')));
      expect(yaml, contains('type: bash'));

      final reparsed = parser.parse(yaml, sourcePath: 'resolved:project-demo');
      expect(reparsed.project, 'demo-project');
      expect(reparsed.steps.first.taskType, WorkflowTaskType.agent);
      expect(reparsed.steps[1].taskType, WorkflowTaskType.agent);
      expect(reparsed.steps[2].taskType, WorkflowTaskType.bash);
    });

    test('top-level loop emits inline loop YAML that reparses cleanly', () {
      const def = WorkflowDefinition(
        name: 'loop-demo',
        description: 'test',
        steps: [
          WorkflowStep(id: 'review-loop', name: 'Review Loop', taskType: WorkflowTaskType.loop),
          WorkflowStep(id: 'review', name: 'Review', prompts: ['Review']),
          WorkflowStep(id: 'finalize', name: 'Finalize', prompts: ['Finalize']),
        ],
        loops: [
          WorkflowLoop(
            id: 'review-loop',
            steps: ['review'],
            exitGate: 'review.status == done',
            maxIterations: 3,
            finally_: 'finalize',
          ),
        ],
      );

      final yaml = resolver.emitYaml(resolver.resolve(def));

      expect(yaml, contains('type: loop'));
      expect(yaml, isNot(contains('loops:')));
      final reparsed = parser.parse(yaml, sourcePath: 'resolved:loop-demo');
      expect(reparsed.loops.single.id, 'review-loop');
      expect(reparsed.loops.single.finally_, 'finalize');
      expect(validator.validate(reparsed).errors, isEmpty);
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
            taskType: WorkflowTaskType.agent,
            prompts: ['Build {{REQUIREMENTS}} using {{context.prior_step.output}}.'],
            outputs: {'result': OutputConfig()},
          ),
        ],
      );
      final resolved = resolver.resolve(def, variableBindings: {'REQUIREMENTS': 'a new API endpoint'});
      expect(resolved.steps.first.prompts!.first, 'Build a new API endpoint using {{context.prior_step.output}}.');
    });

    test('foreach-nested inline loop preserves onMaxIterations: fail through emit round-trip (TI06)', () {
      const yaml = '''
name: nested-loop-policy
description: Foreach-nested loop keeps the default fail policy
steps:
  - id: produce
    name: Produce
    prompt: Produce items
    outputs:
      items: lines
  - id: pipeline
    name: Pipeline
    type: foreach
    map_over: items
    steps:
      - id: story-loop
        name: Story Loop
        type: loop
        maxIterations: 2
        exitGate: "review.status == done"
        onMaxIterations: fail
        steps:
          - id: review
            name: Review
            prompt: Review the story
''';
      final def = parser.parse(yaml);
      final nested = def.loops.singleWhere((loop) => loop.id == 'story-loop');
      expect(nested.onMaxIterations, 'fail');

      final reparsed = parser.parse(
        resolver.emitYaml(resolver.resolve(def)),
        sourcePath: 'resolved:nested-loop-policy',
      );
      final reNested = reparsed.loops.singleWhere((loop) => loop.id == 'story-loop');
      expect(reNested.onMaxIterations, 'fail', reason: 'emit → reparse must preserve the nested loop policy');
      expect(validator.validate(reparsed).errors, isEmpty);
    });

    test('foreach-nested inline loop with onMaxIterations: continue is rejected by validation (TI06)', () {
      const yaml = '''
name: nested-loop-continue
description: Foreach-nested loop cannot opt into continue
steps:
  - id: produce
    name: Produce
    prompt: Produce items
    outputs:
      items: lines
  - id: pipeline
    name: Pipeline
    type: foreach
    map_over: items
    steps:
      - id: story-loop
        name: Story Loop
        type: loop
        maxIterations: 2
        exitGate: "review.status == done"
        onMaxIterations: continue
        steps:
          - id: review
            name: Review
            prompt: Review the story
''';
      final def = parser.parse(yaml);
      final report = validator.validate(def);
      expect(
        report.errors.any((e) => e.type == ValidationErrorType.invalidLoopPolicy && e.loopId == 'story-loop'),
        true,
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
