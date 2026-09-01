part of '../workflow_definition_validator.dart';

extension _WorkflowGateRules on WorkflowDefinitionValidator {
  void _validateStepEntryGates(WorkflowDefinition definition, List<WorkflowValidationError> errors) {
    for (final step in definition.steps) {
      final expression = step.entryGate;
      if (expression == null || expression.trim().isEmpty) continue;
      for (final condition in GateEvaluator.leafConditions(expression)) {
        if (!GateEvaluator.isConditionValid(condition)) {
          errors.add(
            _err(
              WorkflowValidationErrorType.invalidGate,
              'Step "${step.id}" has invalid entryGate expression: "$condition". '
              'Expected: "<key> <operator> <value>" or "<key> isEmpty".',
              stepId: step.id,
            ),
          );
        }
      }
    }
  }

  void _validateLoopGateExpressions(WorkflowDefinition definition, List<WorkflowValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();
    final stepsById = {for (final step in definition.steps) step.id: step};

    for (final loop in definition.loops) {
      // entryGate is evaluated before the loop body runs, so a bare key produced
      // only inside the loop body would resolve to zero on iteration 1 and skip
      // the loop. Restrict entry-gate bare keys to variables + prior steps;
      // exit-gate bare keys may also reference loop-body outputs.
      final entryGateBareKeys = _loopGateBareKeys(definition, loop, stepsById, includeLoopBody: false);
      final exitGateBareKeys = _loopGateBareKeys(definition, loop, stepsById, includeLoopBody: true);
      final gates = {'entryGate': (loop.entryGate, entryGateBareKeys), 'exitGate': (loop.exitGate, exitGateBareKeys)};
      for (final gateEntry in gates.entries) {
        final (expression, validBareKeys) = gateEntry.value;
        if (expression == null || expression.trim().isEmpty) continue;

        for (final condition in GateEvaluator.leafConditions(expression)) {
          final referencedKey = GateEvaluator.referencedKey(condition);
          if (referencedKey == null) {
            errors.add(
              _err(
                WorkflowValidationErrorType.invalidGate,
                'Loop "${loop.id}" has invalid ${gateEntry.key} expression: "$condition". '
                'Expected: "<key> <operator> <value>" or "<key> isEmpty".',
                loopId: loop.id,
              ),
            );
            continue;
          }
          if (!referencedKey.contains('.')) {
            if (!validBareKeys.contains(referencedKey)) {
              final hint = gateEntry.key == 'entryGate' && exitGateBareKeys.contains(referencedKey)
                  ? ' (key is produced inside the loop body; entryGate runs before iteration 1 and cannot read it)'
                  : '';
              errors.add(
                _err(
                  WorkflowValidationErrorType.invalidReference,
                  'Loop "${loop.id}" ${gateEntry.key} references unknown context key "$referencedKey"$hint.',
                  loopId: loop.id,
                ),
              );
            }
            continue;
          }

          final referencedStepId = _gateReferencedStepId(referencedKey);
          if (!stepIds.contains(referencedStepId)) {
            errors.add(
              _err(
                WorkflowValidationErrorType.invalidReference,
                'Loop "${loop.id}" ${gateEntry.key} references non-existent step "$referencedStepId".',
                loopId: loop.id,
              ),
            );
          }
        }
      }
    }
  }

  Set<String> _loopGateBareKeys(
    WorkflowDefinition definition,
    WorkflowLoop loop,
    Map<String, WorkflowStep> stepsById, {
    required bool includeLoopBody,
  }) {
    final loopStepIds = loop.steps.toSet();
    final firstLoopStepIndex = definition.steps.indexWhere((step) => loopStepIds.contains(step.id));
    final keys = <String>{...definition.variables.keys};

    // If indexWhere returned -1 (loop body steps not present in definition.steps,
    // a malformed definition caught separately by reference validation), treat
    // the "prior to loop" window as empty rather than the whole step list.
    final priorWindowEnd = firstLoopStepIndex >= 0 ? firstLoopStepIndex : 0;
    for (var i = 0; i < priorWindowEnd; i++) {
      keys.addAll(definition.steps[i].outputKeys.where((key) => !key.contains('.')));
    }

    if (includeLoopBody) {
      for (final stepId in loop.steps) {
        keys.addAll(stepsById[stepId]?.outputKeys.where((key) => !key.contains('.')) ?? const <String>[]);
      }
    }

    return keys;
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
