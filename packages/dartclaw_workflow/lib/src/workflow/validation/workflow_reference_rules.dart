part of '../workflow_definition_validator.dart';

extension _WorkflowReferenceRules on WorkflowDefinitionValidator {
  void _validateSkillReferences(WorkflowDefinition definition, List<ValidationError> errors) {
    if (skillRegistry == null) return;

    for (final step in definition.steps) {
      if (step.skill == null) continue;

      final error = skillRegistry!.validateRef(step.skill!);
      if (error != null) {
        errors.add(
          ValidationError(
            message: 'Step "${step.id}": $error',
            type: ValidationErrorType.invalidReference,
            stepId: step.id,
          ),
        );
        continue; // Skip harness checks if skill doesn't exist.
      }

      final stepProvider = step.provider;
      if (stepProvider != null) {
        final isRoleAlias = workflowRoleDefaultAliases.contains(stepProvider);
        // Explicit provider: hard error if skill not native for that harness.
        if (!stepProvider.startsWith('@') && !isRoleAlias && !skillRegistry!.isNativeFor(step.skill!, stepProvider)) {
          final skill = skillRegistry!.getByName(step.skill!);
          final available = skill?.nativeHarnesses.join(', ') ?? 'none';
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}": skill "${step.skill}" not available '
                  'for provider "$stepProvider". '
                  'Skill is native for: $available. '
                  'Install it in the provider\'s skill directory or remove the '
                  'explicit provider.',
              type: ValidationErrorType.invalidReference,
              stepId: step.id,
            ),
          );
        }
      }

      if (stepProvider == null || workflowRoleDefaultAliases.contains(stepProvider)) {
        // Default provider: warn if skill only found in one harness.
        final skill = skillRegistry!.getByName(step.skill!);
        if (skill != null && skill.nativeHarnesses.length == 1) {
          WorkflowDefinitionValidator._log.warning(
            'Step "${step.id}": skill "${step.skill}" found only in '
            '${skill.nativeHarnesses.first} harness. If the default provider '
            'changes, the skill may not be available.',
          );
        }
      }
    }
  }

  void _validateVariableReferences(WorkflowDefinition definition, List<ValidationError> errors) {
    final declaredVars = definition.variables.keys.toSet();
    if (definition.project != null) {
      final workflowProjectRefs = _engine.extractVariableReferences(definition.project!);
      for (final ref in workflowProjectRefs) {
        if (!declaredVars.contains(ref)) {
          errors.add(
            ValidationError(
              message: 'Workflow project field references undeclared variable "{{$ref}}".',
              type: ValidationErrorType.invalidReference,
            ),
          );
        }
      }
    }

    // Build a step-id → enclosing-map-aliases lookup so that substep prompts
    // inside a foreach/map can reference the controller's `as:` alias without
    // the extractor flagging it as an undeclared variable.
    final aliasesByStepId = <String, Set<String>>{};
    for (final step in definition.steps) {
      if (step.mapAlias != null) {
        aliasesByStepId.putIfAbsent(step.id, () => <String>{}).add(step.mapAlias!);
      }
      if (step.isForeachController && step.mapAlias != null) {
        for (final childId in step.foreachSteps!) {
          aliasesByStepId.putIfAbsent(childId, () => <String>{}).add(step.mapAlias!);
        }
      }
    }

    for (final step in definition.steps) {
      final aliases = aliasesByStepId[step.id];
      // Extract variable references from all prompts combined (prompts optional for skill steps).
      final allPromptRefs = <String>{
        for (final p in step.prompts ?? const <String>[]) ..._engine.extractVariableReferences(p, mapAliases: aliases),
      };
      for (final ref in allPromptRefs) {
        if (!declaredVars.contains(ref)) {
          errors.add(
            ValidationError(
              message: 'Step "${step.id}" prompt references undeclared variable "{{$ref}}".',
              type: ValidationErrorType.invalidReference,
              stepId: step.id,
            ),
          );
        }
      }
      if (step.project != null) {
        final projectRefs = _engine.extractVariableReferences(step.project!, mapAliases: aliases);
        for (final ref in projectRefs) {
          if (!declaredVars.contains(ref)) {
            errors.add(
              ValidationError(
                message: 'Step "${step.id}" project field references undeclared variable "{{$ref}}".',
                type: ValidationErrorType.invalidReference,
                stepId: step.id,
              ),
            );
          }
        }
      }
      for (final name in step.workflowVariables) {
        if (!declaredVars.contains(name)) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" declares workflowVariables entry "$name" '
                  'but the workflow has no top-level variable with that name.',
              type: ValidationErrorType.invalidReference,
              stepId: step.id,
            ),
          );
        }
      }
    }
  }

  void _validateMapAliases(WorkflowDefinition definition, List<ValidationError> errors) {
    final declaredVars = definition.variables.keys.toSet();
    for (final step in definition.steps) {
      final alias = step.mapAlias;
      if (alias == null) continue;
      if (!step.isMapStep) {
        errors.add(
          ValidationError(
            message:
                'Step "${step.id}": "as: $alias" is only valid on map/foreach controllers '
                '(steps that declare map_over).',
            type: ValidationErrorType.invalidReference,
            stepId: step.id,
          ),
        );
      }
      if (declaredVars.contains(alias)) {
        errors.add(
          ValidationError(
            message:
                'Step "${step.id}": "as: $alias" collides with a declared workflow variable '
                '(pick a different identifier).',
            type: ValidationErrorType.invalidReference,
            stepId: step.id,
          ),
        );
      }
    }
  }

  void _validateContextKeyConsistency(WorkflowDefinition definition, List<ValidationError> errors) {
    // Build set of step IDs that belong to each loop
    final stepToLoops = <String, Set<String>>{};
    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        stepToLoops.putIfAbsent(stepId, () => {}).add(loop.id);
      }
    }

    // For each step, collect all context keys produced by preceding steps
    // and by steps in the same loop (for loop-aware validation).
    final producedSoFar = <String>{};
    for (var i = 0; i < definition.steps.length; i++) {
      final step = definition.steps[i];

      // Keys produced by all steps in the same loop(s) as this step
      final loopProduced = <String>{};
      final myLoops = stepToLoops[step.id] ?? {};
      if (myLoops.isNotEmpty) {
        for (final loop in definition.loops) {
          if (myLoops.contains(loop.id)) {
            for (final loopStepId in loop.steps) {
              final loopStep = definition.steps.firstWhere(
                (s) => s.id == loopStepId,
                orElse: () => step, // unreachable if loop references are valid
              );
              loopProduced.addAll(loopStep.outputKeys);
            }
          }
        }
      }

      for (final input in step.inputs) {
        if (!producedSoFar.contains(input) && !loopProduced.contains(input)) {
          errors.add(
            ValidationError(
              message: 'Step "${step.id}" reads context key "$input" but no preceding step declares it as an output.',
              type: ValidationErrorType.contextInconsistency,
              stepId: step.id,
            ),
          );
        }
      }

      // Add this step's outputs to produced set for subsequent steps
      producedSoFar.addAll(step.outputKeys);
    }
  }

  void _validateMapOverReferences(WorkflowDefinition definition, List<ValidationError> errors) {
    // Build the set of context keys produced by steps in order.
    // For each step with mapOver, verify the referenced key was produced by a prior step.
    final producedSoFar = <String>{};
    for (final step in definition.steps) {
      final mapOver = step.mapOver;
      if (mapOver != null) {
        if (!producedSoFar.contains(mapOver)) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" mapOver references "$mapOver" but no prior step '
                  'declares it as a contextOutput.',
              type: ValidationErrorType.contextInconsistency,
              stepId: step.id,
            ),
          );
        }
      }
      producedSoFar.addAll(step.outputKeys);
    }
  }

  WorkflowStep? _findStep(WorkflowDefinition definition, String stepId) {
    for (final step in definition.steps) {
      if (step.id == stepId) return step;
    }
    return null;
  }

  String? _resolveContinueTargetStepId(WorkflowDefinition definition, int stepIndex, WorkflowStep step) {
    final ref = step.continueSession;
    if (ref == null) return null;
    if (ref == '@previous') {
      return stepIndex > 0 ? definition.steps[stepIndex - 1].id : null;
    }
    return ref;
  }
}
