import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  group('loop gate expressions', () {
    test('loop entryGate is validated alongside exitGate', () {
      final def = buildDef(
        steps: [
          step(id: 's1'),
          step(id: 's2', name: 'S2', prompt: 'p'),
        ],
        loops: [
          const WorkflowLoop(
            id: 'lp',
            steps: ['s1'],
            maxIterations: 3,
            entryGate: 's2.findings_count > 0',
            exitGate: 's1.status == done',
          ),
        ],
      );

      expect(validator.validate(def).errors, isEmpty);
    });

    test('loop gates accept bare context keys', () {
      final def = buildDef(
        steps: [
          step(
            id: 'review-aggregate',
            outputs: {
              'gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
            },
          ),
          step(
            id: 's1',
            outputs: {
              'gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
            },
          ),
        ],
        loops: [
          const WorkflowLoop(
            id: 'lp',
            steps: ['s1'],
            maxIterations: 3,
            entryGate: 'gating_findings_count > 0',
            exitGate: 'gating_findings_count == 0',
          ),
        ],
      );

      expect(validator.validate(def).errors, isEmpty);
    });

    test('loop gates reject unknown bare context keys', () {
      final def = buildDef(
        steps: [
          step(
            id: 'review-aggregate',
            outputs: {
              'gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
            },
          ),
          step(id: 's1'),
        ],
        loops: [
          const WorkflowLoop(
            id: 'lp',
            steps: ['s1'],
            maxIterations: 3,
            entryGate: 'gating_finding_count > 0',
            exitGate: 'gating_findings_count == 0',
          ),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<WorkflowValidationError>()
              .having((error) => error.type, 'type', WorkflowValidationErrorType.invalidReference)
              .having((error) => error.loopId, 'loopId', 'lp')
              .having((error) => error.message, 'message', contains('gating_finding_count')),
        ),
      );
    });

    test('loop entryGate rejects bare keys produced only inside the loop body', () {
      // The entry gate is evaluated before the first child step runs, so a bare key
      // emitted only inside the loop body would resolve to zero on iteration 1 and
      // silently skip the loop. The exit gate may still reference the same key.
      final def = buildDef(
        steps: [
          step(
            id: 'inner',
            outputs: {
              'gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
            },
          ),
        ],
        loops: [
          const WorkflowLoop(
            id: 'lp',
            steps: ['inner'],
            maxIterations: 3,
            entryGate: 'gating_findings_count > 0',
            exitGate: 'gating_findings_count == 0',
          ),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<WorkflowValidationError>()
              .having((error) => error.type, 'type', WorkflowValidationErrorType.invalidReference)
              .having((error) => error.loopId, 'loopId', 'lp')
              .having((error) => error.message, 'message', contains('gating_findings_count'))
              .having((error) => error.message, 'message', contains('inside the loop body')),
        ),
      );
      // exitGate should be accepted — no invalidReference error on the same loop for that gate.
      final exitGateErrors = errors.where(
        (e) =>
            e.type == WorkflowValidationErrorType.invalidReference &&
            e.loopId == 'lp' &&
            e.message.contains('exitGate'),
      );
      expect(exitGateErrors, isEmpty);
    });

    test('invalid loop entryGate produces invalidGate error', () {
      final def = buildDef(
        steps: [step(id: 's1')],
        loops: [
          const WorkflowLoop(
            id: 'lp',
            steps: ['s1'],
            maxIterations: 3,
            entryGate: 's1.status INVALID done',
            exitGate: 's1.status == done',
          ),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: WorkflowValidationErrorType.invalidGate, loopId: 'lp'), isTrue);
    });
  });

  group('step entryGate validation', () {
    test('accepts bare-key and stepId.key forms', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'prd',
            name: 'PRD',
            prompts: ['p'],
            outputs: {'prd': OutputConfig(), 'prd_source': OutputConfig()},
          ),
          WorkflowStep(
            id: 'review-prd',
            name: 'Review',
            prompts: ['r'],
            entryGate: 'prd_source == synthesized',
            inputs: ['prd'],
          ),
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            prompts: ['p'],
            entryGate: 'review-prd.findings_count > 0',
            inputs: ['prd'],
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, type: WorkflowValidationErrorType.invalidGate), isFalse);
    });

    test('accepts unary empty checks', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'discover', name: 'Discover', prompts: ['p'], outputs: {'story_specs': OutputConfig()}),
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            prompts: ['p'],
            entryGate: 'story_specs.items isEmpty || story_specs == null',
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, type: WorkflowValidationErrorType.invalidGate), isFalse);
    });

    test('rejects malformed entryGate expression', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
          WorkflowStep(id: 's2', name: 'S2', prompts: ['p'], entryGate: 'not a valid gate'),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, type: WorkflowValidationErrorType.invalidGate, stepId: 's2'), isTrue);
    });

    test('accepts slash, quoted and spaced comparison values, and compound &&', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 's1',
            name: 'S1',
            prompts: ['p'],
            outputs: {'branch': OutputConfig(), 'label': OutputConfig(), 'quoted': OutputConfig()},
          ),
          WorkflowStep(
            id: 's2',
            name: 'S2',
            prompts: ['p'],
            entryGate: 's1.branch == feature/foo && s1.quoted == "feature/foo" && s1.label == needs review',
          ),
        ],
      );
      expect(hasError(validator.validate(def).errors, type: WorkflowValidationErrorType.invalidGate), isFalse);
    });

    for (final malformed in const ['s1.score > 0 < 1', 's1.status INVALID done']) {
      test('rejects malformed entryGate "$malformed"', () {
        final def =
            WorkflowDefinition(
              name: 'wf',
              description: 'd',
              steps: const [
                WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
              ],
            ).copyWith(
              steps: [
                const WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
                WorkflowStep(id: 's2', name: 'S2', prompts: const ['p'], entryGate: malformed),
              ],
            );
        expect(
          hasError(validator.validate(def).errors, type: WorkflowValidationErrorType.invalidGate, stepId: 's2'),
          isTrue,
        );
      });
    }
  });

  // The validator and the evaluator read one gate-grammar declaration, so
  // neither can accept an expression the other rejects.
  group('single gate-grammar declaration', () {
    const expression = 'review_report_path isNotEmpty && findings_count < 5';
    const rejected = 'plan.status == = accepted';

    WorkflowDefinition defWith({required String stepGate, required String loopGate}) => WorkflowDefinition(
      name: 'wf',
      description: 'd',
      steps: [
        const WorkflowStep(
          id: 'review',
          name: 'Review',
          prompts: ['p'],
          outputs: {'review_report_path': OutputConfig(), 'findings_count': OutputConfig()},
        ),
        WorkflowStep(id: 'gated', name: 'Gated', prompts: const ['p'], entryGate: stepGate),
      ],
      loops: [
        WorkflowLoop(id: 'lp', steps: const ['gated'], maxIterations: 2, exitGate: loopGate),
      ],
    );

    test('an expression both sides accept validates clean and evaluates', () {
      final report = validator.validate(defWith(stepGate: expression, loopGate: expression));
      expect(hasError(report.errors, type: WorkflowValidationErrorType.invalidGate), isFalse);

      final context = WorkflowContext(data: {'review_report_path': 'reviews/r.md', 'findings_count': 2});
      expect(GateEvaluator().evaluate(expression, context), isTrue);
    });

    test('an expression neither side can parse is rejected by both, naming the expression', () {
      final report = validator.validate(defWith(stepGate: rejected, loopGate: rejected));
      final gateErrors = report.errors.where((error) => error.type == WorkflowValidationErrorType.invalidGate);
      expect(gateErrors, isNotEmpty);
      expect(gateErrors.every((error) => error.message.contains(rejected)), isTrue);

      expect(GateEvaluator().evaluate(rejected, WorkflowContext()), isFalse);
    });
  });
}
