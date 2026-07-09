import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  WorkflowDefinition topLevelLoopDef(String onMaxIterations) => buildDef(
    steps: const [
      WorkflowStep(id: 'body', name: 'Body', prompts: ['p']),
    ],
    loops: [
      WorkflowLoop(
        id: 'l1',
        steps: const ['body'],
        maxIterations: 3,
        exitGate: 'body.status == done',
        onMaxIterations: onMaxIterations,
      ),
    ],
  );

  test('fail and continue both validate for a top-level loop', () {
    for (final policy in const ['fail', 'continue']) {
      final errors = validator.validate(topLevelLoopDef(policy)).errors;
      expect(
        hasError(errors, type: ValidationErrorType.invalidLoopPolicy),
        false,
        reason: 'policy "$policy" must validate for a top-level loop',
      );
    }
  });

  test('an unknown onMaxIterations value fails validation naming the loop id', () {
    final errors = validator.validate(topLevelLoopDef('bogus')).errors;
    expect(hasError(errors, type: ValidationErrorType.invalidLoopPolicy, loopId: 'l1', messageContains: 'bogus'), true);
  });

  WorkflowDefinition nestedLoopDef(String onMaxIterations) => WorkflowDefinition(
    name: 'wf',
    description: 'd',
    steps: [
      step(id: 'produce', name: 'Produce', prompt: 'p', outputs: {'items': const OutputConfig()}),
      const WorkflowStep(id: 'review', name: 'Review', prompts: ['p']),
      const WorkflowStep(
        id: 'pipeline',
        name: 'Pipeline',
        taskType: WorkflowTaskType.foreach,
        mapOver: 'items',
        foreachSteps: ['nested-loop'],
      ),
    ],
    loops: [
      WorkflowLoop(
        id: 'nested-loop',
        steps: const ['review'],
        maxIterations: 2,
        exitGate: 'review.status == done',
        onMaxIterations: onMaxIterations,
      ),
    ],
  );

  test('a foreach-nested loop with continue fails validation naming the loop id', () {
    final def = nestedLoopDef(WorkflowLoop.onMaxIterationsContinue);
    final errors = validator.validate(def).errors;
    expect(
      hasError(
        errors,
        type: ValidationErrorType.invalidLoopPolicy,
        loopId: 'nested-loop',
        messageContains: 'nested under a foreach',
      ),
      true,
    );
  });

  test('a foreach-nested loop with escalate validates', () {
    final errors = validator.validate(nestedLoopDef(WorkflowLoop.onMaxIterationsEscalate)).errors;
    expect(hasError(errors, type: ValidationErrorType.invalidLoopPolicy), false);
  });

  test('a top-level loop with escalate fails validation naming the loop id', () {
    final errors = validator.validate(topLevelLoopDef(WorkflowLoop.onMaxIterationsEscalate)).errors;
    expect(
      hasError(
        errors,
        type: ValidationErrorType.invalidLoopPolicy,
        loopId: 'l1',
        messageContains: 'not nested under a foreach',
      ),
      true,
    );
  });

  test('a foreach-nested loop with the default fail policy validates', () {
    final errors = validator.validate(nestedLoopDef(WorkflowLoop.onMaxIterationsFail)).errors;
    expect(hasError(errors, type: ValidationErrorType.invalidLoopPolicy), false);
  });
}
