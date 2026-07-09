part of '../workflow_definition_validator.dart';

extension _WorkflowLoopPolicyRules on WorkflowDefinitionValidator {
  /// Validates each loop's `onMaxIterations` policy.
  ///
  /// `continue` is a top-level loop policy; `escalate` is its foreach-nested
  /// counterpart for remediation loops that should pause for review.
  void _validateLoopMaxIterationsPolicy(WorkflowDefinition definition, List<ValidationError> errors) {
    const allowed = {
      WorkflowLoop.onMaxIterationsFail,
      WorkflowLoop.onMaxIterationsContinue,
      WorkflowLoop.onMaxIterationsEscalate,
    };
    final foreachNestedLoopIds = <String>{
      for (final step in definition.steps)
        if (step.foreachSteps != null) ...step.foreachSteps!,
    };

    for (final loop in definition.loops) {
      if (!allowed.contains(loop.onMaxIterations)) {
        errors.add(
          _err(
            ValidationErrorType.invalidLoopPolicy,
            'Loop "${loop.id}" has invalid onMaxIterations "${loop.onMaxIterations}" '
            '(must be "${WorkflowLoop.onMaxIterationsFail}", "${WorkflowLoop.onMaxIterationsContinue}", '
            'or "${WorkflowLoop.onMaxIterationsEscalate}").',
            loopId: loop.id,
          ),
        );
        continue;
      }

      if (loop.onMaxIterations == WorkflowLoop.onMaxIterationsContinue && foreachNestedLoopIds.contains(loop.id)) {
        errors.add(
          _err(
            ValidationErrorType.invalidLoopPolicy,
            'Loop "${loop.id}" is nested under a foreach body and cannot use '
            'onMaxIterations "${WorkflowLoop.onMaxIterationsContinue}"; nested loops must keep '
            'fail-on-exhaustion or opt into "${WorkflowLoop.onMaxIterationsEscalate}".',
            loopId: loop.id,
          ),
        );
      }

      if (loop.onMaxIterations == WorkflowLoop.onMaxIterationsEscalate && !foreachNestedLoopIds.contains(loop.id)) {
        errors.add(
          _err(
            ValidationErrorType.invalidLoopPolicy,
            'Loop "${loop.id}" is not nested under a foreach body and cannot use '
            'onMaxIterations "${WorkflowLoop.onMaxIterationsEscalate}"; top-level loops must use '
            '"${WorkflowLoop.onMaxIterationsContinue}" for max-iteration fall-through.',
            loopId: loop.id,
          ),
        );
      }
    }
  }
}
