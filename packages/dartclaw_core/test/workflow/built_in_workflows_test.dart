import 'package:dartclaw_core/dartclaw_core.dart'
    show WorkflowDefinitionParser, WorkflowDefinitionValidator, builtInWorkflowYaml;
import 'package:test/test.dart';

void main() {
  final parser = WorkflowDefinitionParser();
  final validator = WorkflowDefinitionValidator();

  group('builtInWorkflowYaml map', () {
    test('contains exactly 10 entries', () {
      expect(builtInWorkflowYaml, hasLength(10));
    });

    test('contains expected workflow names as keys', () {
      expect(
        builtInWorkflowYaml.keys,
        containsAll([
          'spec-and-implement',
          'research-and-evaluate',
          'fix-bug',
          'refactor',
          'review-and-remediate',
          'plan-and-execute',
          'adversarial-dev',
          'idea-to-pr',
          'workflow-builder',
          'comprehensive-pr-review',
        ]),
      );
    });
  });

  group('each built-in workflow parses and validates', () {
    for (final entry in builtInWorkflowYaml.entries) {
      test('${entry.key}: parses without error', () {
        expect(() => parser.parse(entry.value, sourcePath: 'built-in:${entry.key}'), returnsNormally);
      });

      test('${entry.key}: validates without errors', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        final report = validator.validate(definition);
        expect(report.errors, isEmpty, reason: report.errors.join('; '));
      });

      test('${entry.key}: definition.name matches map key', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        expect(definition.name, equals(entry.key));
      });

      test('${entry.key}: description is non-empty', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        expect(definition.description, isNotEmpty);
      });
    }
  });

  group('spec-and-implement', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['spec-and-implement']!,
      sourcePath: 'built-in:spec-and-implement',
    );

    test('has 6 steps', () {
      expect(definition.steps, hasLength(6));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['research', 'spec', 'implement', 'code-review', 'gap-analysis', 'remediate']));
    });

    test('declares FEATURE (required) and PROJECT (optional) variables', () {
      expect(definition.variables['FEATURE']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('research step has provider: claude', () {
      final research = definition.steps.firstWhere((s) => s.id == 'research');
      expect(research.provider, equals('claude'));
    });

    test('spec step has provider: claude', () {
      final spec = definition.steps.firstWhere((s) => s.id == 'spec');
      expect(spec.provider, equals('claude'));
    });

    test('implement step has review: always', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.review.name, equals('always'));
    });

    test('remediate step has review: always', () {
      final remediate = definition.steps.firstWhere((s) => s.id == 'remediate');
      expect(remediate.review.name, equals('always'));
    });

    test('code-review step has gate on implement.status', () {
      final codeReview = definition.steps.firstWhere((s) => s.id == 'code-review');
      expect(codeReview.gate, contains('implement.status'));
    });

    test('remediate step has gate on gap-analysis.status', () {
      final remediate = definition.steps.firstWhere((s) => s.id == 'remediate');
      expect(remediate.gate, contains('gap-analysis.status'));
    });

    test('spec step outputs acceptance_criteria', () {
      final spec = definition.steps.firstWhere((s) => s.id == 'spec');
      expect(spec.contextOutputs, contains('acceptance_criteria'));
    });

    test('code-review step inputs acceptance_criteria', () {
      final codeReview = definition.steps.firstWhere((s) => s.id == 'code-review');
      expect(codeReview.contextInputs, contains('acceptance_criteria'));
    });

    test('gap-analysis step inputs acceptance_criteria', () {
      final gapAnalysis = definition.steps.firstWhere((s) => s.id == 'gap-analysis');
      expect(gapAnalysis.contextInputs, contains('acceptance_criteria'));
    });

    test('research prompt includes planning granularity guidance', () {
      final research = definition.steps.firstWhere((s) => s.id == 'research');
      expect(research.prompt, contains('architecture'));
    });

    test('code-review prompt includes evaluator anti-leniency text', () {
      final codeReview = definition.steps.firstWhere((s) => s.id == 'code-review');
      expect(codeReview.prompt, contains('independent evaluator'));
      expect(codeReview.prompt, contains('NOT the agent'));
    });

    test('gap-analysis prompt includes evaluator anti-leniency text', () {
      final gapAnalysis = definition.steps.firstWhere((s) => s.id == 'gap-analysis');
      expect(gapAnalysis.prompt, contains('independent evaluator'));
    });
  });

  group('research-and-evaluate', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['research-and-evaluate']!,
      sourcePath: 'built-in:research-and-evaluate',
    );

    test('has 4 steps', () {
      expect(definition.steps, hasLength(4));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['research', 'evaluate', 'synthesize', 'recommendation']));
    });

    test('declares QUESTION (required) and OPTIONS (optional with default)', () {
      expect(definition.variables['QUESTION']?.required, isTrue);
      expect(definition.variables['OPTIONS']?.required, isFalse);
      expect(definition.variables['OPTIONS']?.defaultValue, equals(''));
    });

    test('research step has provider: claude', () {
      final research = definition.steps.firstWhere((s) => s.id == 'research');
      expect(research.provider, equals('claude'));
    });
  });

  group('fix-bug', () {
    late final definition = parser.parse(builtInWorkflowYaml['fix-bug']!, sourcePath: 'built-in:fix-bug');

    test('has 5 steps', () {
      expect(definition.steps, hasLength(5));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['reproduce', 'diagnose', 'fix', 'test', 'verify']));
    });

    test('declares BUG_DESCRIPTION (required) and PROJECT (optional)', () {
      expect(definition.variables['BUG_DESCRIPTION']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('fix step has review: always and gate on diagnose', () {
      final fix = definition.steps.firstWhere((s) => s.id == 'fix');
      expect(fix.review.name, equals('always'));
      expect(fix.gate, contains('diagnose.status'));
    });

    test('test step has gate on fix', () {
      final test_ = definition.steps.firstWhere((s) => s.id == 'test');
      expect(test_.gate, contains('fix.status'));
    });
  });

  group('refactor', () {
    late final definition = parser.parse(builtInWorkflowYaml['refactor']!, sourcePath: 'built-in:refactor');

    test('has 4 steps', () {
      expect(definition.steps, hasLength(4));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['analyze', 'plan', 'execute', 'verify']));
    });

    test('declares TARGET (required) and PROJECT (optional)', () {
      expect(definition.variables['TARGET']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('execute step has review: always', () {
      final execute = definition.steps.firstWhere((s) => s.id == 'execute');
      expect(execute.review.name, equals('always'));
    });

    test('verify step has gate on execute', () {
      final verify = definition.steps.firstWhere((s) => s.id == 'verify');
      expect(verify.gate, contains('execute.status'));
    });
  });

  group('review-and-remediate', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['review-and-remediate']!,
      sourcePath: 'built-in:review-and-remediate',
    );

    test('has 4 steps', () {
      expect(definition.steps, hasLength(4));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['review', 'gap-analysis', 'remediate', 're-review']));
    });

    test('declares TARGET (required) and PROJECT (optional)', () {
      expect(definition.variables['TARGET']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('has 1 loop with id fix-loop', () {
      expect(definition.loops, hasLength(1));
      expect(definition.loops.first.id, equals('fix-loop'));
    });

    test('loop references steps [gap-analysis, remediate, re-review]', () {
      final loop = definition.loops.first;
      expect(loop.steps, equals(['gap-analysis', 'remediate', 're-review']));
    });

    test('loop has maxIterations: 3', () {
      expect(definition.loops.first.maxIterations, equals(3));
    });

    test('loop has exitGate referencing re-review.findings_count', () {
      expect(definition.loops.first.exitGate, contains('re-review.findings_count'));
    });

    test('remediate step has review: always', () {
      final remediate = definition.steps.firstWhere((s) => s.id == 'remediate');
      expect(remediate.review.name, equals('always'));
    });
  });

  group('plan-and-execute', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['plan-and-execute']!,
      sourcePath: 'built-in:plan-and-execute',
    );

    test('has 3 steps', () {
      expect(definition.steps, hasLength(3));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['plan', 'implement', 'review']));
    });

    test('declares REQUIREMENTS (required), PROJECT (optional), MAX_PARALLEL (optional with default)', () {
      expect(definition.variables['REQUIREMENTS']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
      expect(definition.variables['MAX_PARALLEL']?.required, isFalse);
      expect(definition.variables['MAX_PARALLEL']?.defaultValue, equals('2'));
    });

    test('plan step has type: analysis and no skill field', () {
      final plan = definition.steps.firstWhere((s) => s.id == 'plan');
      expect(plan.type, equals('analysis'));
      expect(plan.skill, isNull);
    });

    test('implement step has type: coding and mapOver: stories', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.type, equals('coding'));
      expect(implement.mapOver, equals('stories'));
    });

    test('implement step is a map step', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.isMapStep, isTrue);
    });

    test('implement step has max_items: 15', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.maxItems, equals(15));
    });

    test('implement step max_parallel is template "{{MAX_PARALLEL}}"', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.maxParallel, equals('{{MAX_PARALLEL}}'));
    });

    test('review step has evaluator: true and mapOver: stories', () {
      final review = definition.steps.firstWhere((s) => s.id == 'review');
      expect(review.evaluator, isTrue);
      expect(review.mapOver, equals('stories'));
    });

    test('review step max_parallel is 3', () {
      final review = definition.steps.firstWhere((s) => s.id == 'review');
      expect(review.maxParallel, equals(3));
    });

    test('review prompt contains implement_results[map.index]', () {
      final review = definition.steps.firstWhere((s) => s.id == 'review');
      expect(review.prompt, contains('implement_results[map.index]'));
    });

    test('plan prompt contains "independent" (independence instruction)', () {
      final plan = definition.steps.firstWhere((s) => s.id == 'plan');
      expect(plan.prompt, contains('independent'));
    });

    test('stepDefaults is non-null and has 3 entries', () {
      expect(definition.stepDefaults, isNotNull);
      expect(definition.stepDefaults!, hasLength(3));
    });

    test('first stepDefaults entry matches "implement*" pattern', () {
      expect(definition.stepDefaults![0].match, equals('implement*'));
    });
  });

  group('adversarial-dev', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['adversarial-dev']!,
      sourcePath: 'built-in:adversarial-dev',
    );

    test('has 5 steps', () {
      expect(definition.steps, hasLength(5));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['scope', 'generate', 'evaluate', 'remediate', 're-evaluate']));
    });

    test('declares TASK (required) and PROJECT (optional)', () {
      expect(definition.variables['TASK']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
      expect(definition.variables.containsKey('MAX_ROUNDS'), isFalse);
    });

    test('evaluate step has evaluator: true (adversarial isolation)', () {
      final evaluate = definition.steps.firstWhere((s) => s.id == 'evaluate');
      expect(evaluate.evaluator, isTrue);
    });

    test('re-evaluate step has evaluator: true', () {
      final reEvaluate = definition.steps.firstWhere((s) => s.id == 're-evaluate');
      expect(reEvaluate.evaluator, isTrue);
    });

    test('generate step has review: always', () {
      final generate = definition.steps.firstWhere((s) => s.id == 'generate');
      expect(generate.review.name, equals('always'));
    });

    test('remediate step has review: always and gate on evaluate', () {
      final remediate = definition.steps.firstWhere((s) => s.id == 'remediate');
      expect(remediate.review.name, equals('always'));
      expect(remediate.gate, contains('evaluate.evaluation_passed'));
    });

    test('has 1 loop: adversarial-loop over [remediate, re-evaluate]', () {
      expect(definition.loops, hasLength(1));
      expect(definition.loops.first.id, equals('adversarial-loop'));
      expect(definition.loops.first.steps, equals(['remediate', 're-evaluate']));
    });

    test('adversarial-loop has maxIterations: 3', () {
      expect(definition.loops.first.maxIterations, equals(3));
    });

    test('adversarial-loop exitGate references re-evaluate.evaluation_passed', () {
      expect(definition.loops.first.exitGate, contains('re-evaluate.evaluation_passed'));
    });

    test('evaluate prompt includes evaluator anti-leniency text', () {
      final evaluate = definition.steps.firstWhere((s) => s.id == 'evaluate');
      expect(evaluate.prompt, contains('independent evaluator'));
      expect(evaluate.prompt, contains('NOT to find reasons to approve'));
    });

    test('stepDefaults is non-null and has 3 entries', () {
      expect(definition.stepDefaults, isNotNull);
      expect(definition.stepDefaults!, hasLength(3));
    });

    test('first stepDefaults entry matches "generate*" pattern', () {
      expect(definition.stepDefaults![0].match, equals('generate*'));
    });

    test('second stepDefaults entry matches "evaluate*" pattern', () {
      expect(definition.stepDefaults![1].match, equals('evaluate*'));
    });
  });

  group('idea-to-pr', () {
    late final definition = parser.parse(builtInWorkflowYaml['idea-to-pr']!, sourcePath: 'built-in:idea-to-pr');

    test('has 8 steps', () {
      expect(definition.steps, hasLength(8));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(
        ids,
        equals([
          'plan',
          'approve-plan',
          'implement',
          'validate-build',
          'review-correctness',
          'review-security',
          'review-synthesis',
          'create-pr',
        ]),
      );
    });

    test('declares IDEA (required), PROJECT (optional), BASE_BRANCH (optional with default)', () {
      expect(definition.variables['IDEA']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
      expect(definition.variables['BASE_BRANCH']?.required, isFalse);
      expect(definition.variables['BASE_BRANCH']?.defaultValue, equals('main'));
    });

    test('approve-plan step is type: approval (approval gate)', () {
      final approvePlan = definition.steps.firstWhere((s) => s.id == 'approve-plan');
      expect(approvePlan.type, equals('approval'));
    });

    test('approve-plan step includes a non-empty approval message', () {
      final approvePlan = definition.steps.firstWhere((s) => s.id == 'approve-plan');
      expect(approvePlan.prompt, isNotNull);
      expect(approvePlan.prompt!.trim(), isNotEmpty);
    });

    test('implement step has gate on approve-plan.status', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.gate, contains('approve-plan.status'));
    });

    test('implement step has review: always', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.review.name, equals('always'));
    });

    test('implement step declares branch_name output with source: worktree.branch', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.contextOutputs, contains('branch_name'));
      expect(implement.outputs?['branch_name']?.source, equals('worktree.branch'));
    });

    test('validate-build step is type: bash (deterministic validation)', () {
      final validateBuild = definition.steps.firstWhere((s) => s.id == 'validate-build');
      expect(validateBuild.type, equals('bash'));
    });

    test('validate-build step has gate on implement.status', () {
      final validateBuild = definition.steps.firstWhere((s) => s.id == 'validate-build');
      expect(validateBuild.gate, contains('implement.status'));
    });

    test('validate-build step runs in the implement worktree', () {
      final validateBuild = definition.steps.firstWhere((s) => s.id == 'validate-build');
      expect(validateBuild.workdir, equals('{{context.implement.worktree_path}}'));
    });

    test('review-correctness and review-security are parallel evaluator steps', () {
      final correctness = definition.steps.firstWhere((s) => s.id == 'review-correctness');
      final security = definition.steps.firstWhere((s) => s.id == 'review-security');
      expect(correctness.evaluator, isTrue);
      expect(correctness.parallel, isTrue);
      expect(security.evaluator, isTrue);
      expect(security.parallel, isTrue);
    });

    test('create-pr step is type: bash and gates on review-synthesis.ready_to_merge', () {
      final createPr = definition.steps.firstWhere((s) => s.id == 'create-pr');
      expect(createPr.type, equals('bash'));
      expect(createPr.gate, contains('review-synthesis.ready_to_merge'));
    });

    test('create-pr prompt documents gh assumptions', () {
      final createPr = definition.steps.firstWhere((s) => s.id == 'create-pr');
      expect(createPr.prompt, contains('gh'));
      expect(createPr.prompt, contains('ASSUMPTION'));
      expect(createPr.prompt, contains('CUSTOMIZATION'));
    });

    test('create-pr prompt uses shell-safe branch assignment and body file', () {
      final createPr = definition.steps.firstWhere((s) => s.id == 'create-pr');
      expect(createPr.prompt, contains('branch_name={{context.branch_name}}'));
      expect(createPr.prompt, contains(r'--body-file "$pr_body_file"'));
    });

    test('create-pr step runs in the implement worktree', () {
      final createPr = definition.steps.firstWhere((s) => s.id == 'create-pr');
      expect(createPr.workdir, equals('{{context.implement.worktree_path}}'));
    });

    test('create-pr step consumes branch_name from context', () {
      final createPr = definition.steps.firstWhere((s) => s.id == 'create-pr');
      expect(createPr.contextInputs, contains('branch_name'));
    });

    test('stepDefaults is non-null and has 3 entries', () {
      expect(definition.stepDefaults, isNotNull);
      expect(definition.stepDefaults!, hasLength(3));
    });
  });

  group('workflow-builder', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['workflow-builder']!,
      sourcePath: 'built-in:workflow-builder',
    );

    test('has 5 steps', () {
      expect(definition.steps, hasLength(5));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['design', 'author', 'save', 'validate', 'summarize']));
    });

    test('declares REQUEST (required), WORKFLOW_NAME (required), WORKSPACE_PATH (optional)', () {
      expect(definition.variables['REQUEST']?.required, isTrue);
      expect(definition.variables['WORKFLOW_NAME']?.required, isTrue);
      expect(definition.variables['WORKSPACE_PATH']?.required, isFalse);
    });

    test('save step is type: bash and gates on author.status', () {
      final save = definition.steps.firstWhere((s) => s.id == 'save');
      expect(save.type, equals('bash'));
      expect(save.gate, contains('author.status'));
    });

    test('save step writes workflow YAML via printf, not a heredoc', () {
      final save = definition.steps.firstWhere((s) => s.id == 'save');
      expect(save.prompt, contains('printf'));
      expect(save.prompt, contains('{{context.workflow_yaml}}'));
      expect(save.prompt, isNot(contains('WORKFLOW_EOF')));
    });

    test('validate step is type: bash and invokes dartclaw workflow validate', () {
      final validate = definition.steps.firstWhere((s) => s.id == 'validate');
      expect(validate.type, equals('bash'));
      expect(validate.prompt, contains('workflow validate'));
    });

    test('validate step gates on save.status', () {
      final validate = definition.steps.firstWhere((s) => s.id == 'validate');
      expect(validate.gate, contains('save.status'));
    });

    test('validate step references WORKSPACE_PATH and WORKFLOW_NAME in prompt', () {
      final validate = definition.steps.firstWhere((s) => s.id == 'validate');
      expect(validate.prompt, contains('WORKSPACE_PATH'));
      expect(validate.prompt, contains('WORKFLOW_NAME'));
    });
  });

  group('comprehensive-pr-review', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['comprehensive-pr-review']!,
      sourcePath: 'built-in:comprehensive-pr-review',
    );

    test('declares BRANCH and PR_NUMBER variables (both optional)', () {
      expect(definition.variables['BRANCH']?.required, isFalse);
      expect(definition.variables['PR_NUMBER']?.required, isFalse);
    });

    test('extract-diff step is type: bash', () {
      final extractDiff = definition.steps.firstWhere((s) => s.id == 'extract-diff');
      expect(extractDiff.type, equals('bash'));
    });

    test('extract-diff prompt handles both BRANCH and PR_NUMBER inputs', () {
      final extractDiff = definition.steps.firstWhere((s) => s.id == 'extract-diff');
      expect(extractDiff.prompt, contains('BRANCH'));
      expect(extractDiff.prompt, contains('PR_NUMBER'));
    });

    test('extract-diff prompt documents gh assumptions', () {
      final extractDiff = definition.steps.firstWhere((s) => s.id == 'extract-diff');
      expect(extractDiff.prompt, contains('ASSUMPTION'));
    });

    test('review-correctness and review-security are parallel evaluator steps', () {
      final correctness = definition.steps.firstWhere((s) => s.id == 'review-correctness');
      final security = definition.steps.firstWhere((s) => s.id == 'review-security');
      expect(correctness.evaluator, isTrue);
      expect(correctness.parallel, isTrue);
      expect(security.evaluator, isTrue);
      expect(security.parallel, isTrue);
    });

    test('synthesize step consolidates reviewer findings', () {
      final synthesize = definition.steps.firstWhere((s) => s.id == 'synthesize');
      expect(synthesize.contextInputs, containsAll(['correctness_findings', 'security_findings']));
    });

    test('stepDefaults is non-null', () {
      expect(definition.stepDefaults, isNotNull);
      expect(definition.stepDefaults!.isNotEmpty, isTrue);
    });
  });

  group('prompts use only {{variable}} or {{context.key}} syntax', () {
    // Handlebars conditionals ({{#if}}, {{#each}}) must not appear.
    final handlebarsPattern = RegExp(r'\{\{#');

    for (final entry in builtInWorkflowYaml.entries) {
      test('${entry.key}: no Handlebars conditionals in prompts', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        for (final step in definition.steps) {
          expect(
            handlebarsPattern.hasMatch(step.prompt ?? ''),
            isFalse,
            reason: 'Step "${step.id}" prompt contains Handlebars conditional syntax',
          );
        }
      });
    }
  });
}
