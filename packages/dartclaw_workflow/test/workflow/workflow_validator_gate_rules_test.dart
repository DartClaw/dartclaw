import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  group('gate expressions', () {
    test('valid gate expression produces no error', () {
      final def = buildDef(
        steps: [
          step(id: 's1', outputs: {'status': OutputConfig()}),
          step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status == done'),
        ],
      );
      expect(validator.validate(def).errors, isEmpty);
    });

    test('gate expression accepts slash, quoted, and spaced values', () {
      final def = buildDef(
        steps: [
          step(id: 's1', outputs: {'branch': OutputConfig(), 'label': OutputConfig(), 'quoted': OutputConfig()}),
          step(
            id: 's2',
            name: 'S2',
            prompt: 'p',
            gate: 's1.branch == feature/foo && s1.quoted == "feature/foo" && s1.label == needs review',
          ),
        ],
      );
      expect(validator.validate(def).errors, isEmpty);
    });

    test('gate expression with extra operator syntax produces invalidGate error', () {
      final def = buildDef(
        steps: [
          step(id: 's1', outputs: {'score': OutputConfig()}),
          step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.score > 0 < 1'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidGate), true);
    });

    test('gate referencing non-existent step produces invalidReference error', () {
      final def = buildDef(
        steps: [step(id: 's1', gate: 'nonexistent.status == done')],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidReference), true);
    });

    test('gate with invalid operator produces invalidGate error', () {
      final def = buildDef(
        steps: [
          step(id: 's1'),
          step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status INVALID done'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidGate), true);
    });

    test('compound gate with && is parsed correctly', () {
      final def = buildDef(
        steps: [
          step(id: 's1', outputs: {'status': OutputConfig(), 'score': OutputConfig()}),
          step(id: 's2', name: 'S2', prompt: 'p', gate: 's1.status == done && s1.score >= 90'),
        ],
      );
      expect(validator.validate(def).errors, isEmpty);
    });

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
          isA<ValidationError>()
              .having((error) => error.type, 'type', ValidationErrorType.invalidReference)
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
          isA<ValidationError>()
              .having((error) => error.type, 'type', ValidationErrorType.invalidReference)
              .having((error) => error.loopId, 'loopId', 'lp')
              .having((error) => error.message, 'message', contains('gating_findings_count'))
              .having((error) => error.message, 'message', contains('inside the loop body')),
        ),
      );
      // exitGate should be accepted — no invalidReference error on the same loop for that gate.
      final exitGateErrors = errors.where(
        (e) => e.type == ValidationErrorType.invalidReference && e.loopId == 'lp' && e.message.contains('exitGate'),
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
      expect(hasError(errors, type: ValidationErrorType.invalidGate, loopId: 'lp'), isTrue);
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
      expect(hasError(report.errors, type: ValidationErrorType.invalidGate), isFalse);
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
      expect(hasError(report.errors, type: ValidationErrorType.invalidGate), isFalse);
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
      expect(hasError(report.errors, type: ValidationErrorType.invalidGate, stepId: 's2'), isTrue);
    });
  });
}
