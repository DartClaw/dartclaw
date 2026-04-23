part of '../workflow_definition_validator.dart';

extension _WorkflowGateRules on WorkflowDefinitionValidator {
  void _validateStepEntryGates(WorkflowDefinition definition, List<ValidationError> errors) {
    for (final step in definition.steps) {
      final expression = step.entryGate;
      if (expression == null || expression.trim().isEmpty) continue;
      final conditions = expression.split('&&').map((c) => c.trim());
      for (final condition in conditions) {
        if (!WorkflowDefinitionValidator._entryGateConditionPattern.hasMatch(condition)) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" has invalid entryGate expression: "$condition". '
                  'Expected: "<key> <operator> <value>" (e.g. '
                  '"prd_source == synthesized" or "review.findings_count > 0").',
              type: ValidationErrorType.invalidGate,
              stepId: step.id,
            ),
          );
        }
      }
    }
  }

  void _validateGateExpressions(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();

    for (final step in definition.steps) {
      if (step.gate == null) continue;
      final conditions = step.gate!.split('&&').map((c) => c.trim());
      for (final condition in conditions) {
        final match = WorkflowDefinitionValidator._gateConditionPattern.firstMatch(condition);
        if (match == null) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" has invalid gate expression: "$condition". '
                  'Expected: stepId.key operator value.',
              type: ValidationErrorType.invalidGate,
              stepId: step.id,
            ),
          );
          continue;
        }
        final referencedStepId = _gateReferencedStepId(match.group(1)!);
        if (!stepIds.contains(referencedStepId)) {
          errors.add(
            ValidationError(
              message: 'Step "${step.id}" gate references non-existent step "$referencedStepId".',
              type: ValidationErrorType.invalidReference,
              stepId: step.id,
            ),
          );
        }
      }
    }
  }

  void _validateLoopGateExpressions(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();

    for (final loop in definition.loops) {
      final gates = {'entryGate': loop.entryGate, 'exitGate': loop.exitGate};
      for (final gateEntry in gates.entries) {
        final expression = gateEntry.value;
        if (expression == null || expression.trim().isEmpty) continue;

        final conditions = expression.split('&&').map((c) => c.trim());
        for (final condition in conditions) {
          final match = WorkflowDefinitionValidator._gateConditionPattern.firstMatch(condition);
          if (match == null) {
            errors.add(
              ValidationError(
                message:
                    'Loop "${loop.id}" has invalid ${gateEntry.key} expression: "$condition". '
                    'Expected: stepId.key operator value.',
                type: ValidationErrorType.invalidGate,
                loopId: loop.id,
              ),
            );
            continue;
          }

          final referencedStepId = _gateReferencedStepId(match.group(1)!);
          if (!stepIds.contains(referencedStepId)) {
            errors.add(
              ValidationError(
                message: 'Loop "${loop.id}" ${gateEntry.key} references non-existent step "$referencedStepId".',
                type: ValidationErrorType.invalidReference,
                loopId: loop.id,
              ),
            );
          }
        }
      }
    }
  }

  String _gateReferencedStepId(String rawKey) {
    if (rawKey.startsWith('step.')) {
      final segments = rawKey.split('.');
      if (segments.length >= 3) {
        return segments[1];
      }
    }
    return rawKey.split('.').first;
  }
}
