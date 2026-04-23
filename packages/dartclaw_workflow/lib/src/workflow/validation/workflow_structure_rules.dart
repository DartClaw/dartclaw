part of '../workflow_definition_validator.dart';

extension _WorkflowStructureRules on WorkflowDefinitionValidator {
  void _validateNormalizedNodes(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepById = {for (final step in definition.steps) step.id: step};
    final loopById = {for (final loop in definition.loops) loop.id: loop};
    final seenStepIds = <String>{};

    for (final node in definition.nodes) {
      switch (node) {
        case ActionNode(stepId: final stepId):
          final step = stepById[stepId];
          if (step == null) {
            errors.add(
              ValidationError(
                message: 'Normalized action node references unknown step "$stepId".',
                type: ValidationErrorType.invalidReference,
                stepId: stepId,
              ),
            );
            continue;
          }
          if (step.isMapStep) {
            errors.add(
              ValidationError(
                message: 'Step "$stepId" is map-backed but was normalized as an action node.',
                type: ValidationErrorType.contextInconsistency,
                stepId: stepId,
              ),
            );
          }
          if (step.parallel) {
            errors.add(
              ValidationError(
                message: 'Step "$stepId" is parallel but was normalized as an action node.',
                type: ValidationErrorType.contextInconsistency,
                stepId: stepId,
              ),
            );
          }
          _recordNormalizedStep(stepId, seenStepIds, errors);

        case MapNode(stepId: final stepId):
          final step = stepById[stepId];
          if (step == null) {
            errors.add(
              ValidationError(
                message: 'Normalized map node references unknown step "$stepId".',
                type: ValidationErrorType.invalidReference,
                stepId: stepId,
              ),
            );
            continue;
          }
          if (!step.isMapStep) {
            errors.add(
              ValidationError(
                message: 'Step "$stepId" is not a map step but was normalized as a map node.',
                type: ValidationErrorType.contextInconsistency,
                stepId: stepId,
              ),
            );
          }
          _recordNormalizedStep(stepId, seenStepIds, errors);

        case ParallelGroupNode(stepIds: final stepIds):
          if (stepIds.isEmpty) {
            errors.add(
              const ValidationError(
                message: 'Normalized parallel group must contain at least one step.',
                type: ValidationErrorType.missingField,
              ),
            );
            continue;
          }
          for (final stepId in stepIds) {
            final step = stepById[stepId];
            if (step == null) {
              errors.add(
                ValidationError(
                  message: 'Normalized parallel group references unknown step "$stepId".',
                  type: ValidationErrorType.invalidReference,
                  stepId: stepId,
                ),
              );
              continue;
            }
            if (!step.parallel) {
              errors.add(
                ValidationError(
                  message: 'Parallel group step "$stepId" is missing parallel:true in the authored step.',
                  type: ValidationErrorType.contextInconsistency,
                  stepId: stepId,
                ),
              );
            }
            if (step.isMapStep) {
              errors.add(
                ValidationError(
                  message: 'Parallel group step "$stepId" cannot also be a map step.',
                  type: ValidationErrorType.contextInconsistency,
                  stepId: stepId,
                ),
              );
            }
            _recordNormalizedStep(stepId, seenStepIds, errors);
          }

        case LoopNode(loopId: final loopId, stepIds: final stepIds, finallyStepId: final finallyStepId):
          final loop = loopById[loopId];
          if (loop == null) {
            errors.add(
              ValidationError(
                message: 'Normalized loop node references unknown loop "$loopId".',
                type: ValidationErrorType.invalidReference,
                loopId: loopId,
              ),
            );
            continue;
          }
          if (!_sameStringList(loop.steps, stepIds)) {
            errors.add(
              ValidationError(
                message: 'Loop "$loopId" node step order does not match the authored loop body.',
                type: ValidationErrorType.contextInconsistency,
                loopId: loopId,
              ),
            );
          }
          if (loop.finally_ != finallyStepId) {
            errors.add(
              ValidationError(
                message: 'Loop "$loopId" node finalizer does not match the authored loop finalizer.',
                type: ValidationErrorType.contextInconsistency,
                loopId: loopId,
              ),
            );
          }
          final loopNodeStepIds = <String>[...stepIds];
          if (finallyStepId != null) {
            loopNodeStepIds.add(finallyStepId);
          }
          for (final stepId in loopNodeStepIds) {
            if (!stepById.containsKey(stepId)) {
              errors.add(
                ValidationError(
                  message: 'Loop "$loopId" node references unknown step "$stepId".',
                  type: ValidationErrorType.invalidReference,
                  stepId: stepId,
                  loopId: loopId,
                ),
              );
              continue;
            }
            _recordNormalizedStep(stepId, seenStepIds, errors, loopId: loopId);
          }

        case ForeachNode(stepId: final controllerStepId, childStepIds: final childStepIds):
          final controllerStep = stepById[controllerStepId];
          if (controllerStep == null) {
            errors.add(
              ValidationError(
                message: 'Normalized foreach node references unknown controller step "$controllerStepId".',
                type: ValidationErrorType.invalidReference,
                stepId: controllerStepId,
              ),
            );
            continue;
          }
          if (!controllerStep.isForeachController) {
            errors.add(
              ValidationError(
                message: 'Step "$controllerStepId" is not a foreach controller but was normalized as a foreach node.',
                type: ValidationErrorType.contextInconsistency,
                stepId: controllerStepId,
              ),
            );
          }
          if (childStepIds.isEmpty) {
            errors.add(
              ValidationError(
                message: 'Foreach node "$controllerStepId" must have at least one child step.',
                type: ValidationErrorType.missingField,
                stepId: controllerStepId,
              ),
            );
          }
          _recordNormalizedStep(controllerStepId, seenStepIds, errors);
          for (final childStepId in childStepIds) {
            if (!stepById.containsKey(childStepId)) {
              errors.add(
                ValidationError(
                  message: 'Foreach "$controllerStepId" references unknown child step "$childStepId".',
                  type: ValidationErrorType.invalidReference,
                  stepId: childStepId,
                ),
              );
              continue;
            }
            _recordNormalizedStep(childStepId, seenStepIds, errors);
          }
      }
    }

    for (final step in definition.steps) {
      if (!seenStepIds.contains(step.id)) {
        errors.add(
          ValidationError(
            message: 'Step "${step.id}" is not represented in the normalized execution graph.',
            type: ValidationErrorType.contextInconsistency,
            stepId: step.id,
          ),
        );
      }
    }
  }

  void _recordNormalizedStep(String stepId, Set<String> seenStepIds, List<ValidationError> errors, {String? loopId}) {
    if (!seenStepIds.add(stepId)) {
      errors.add(
        ValidationError(
          message: 'Step "$stepId" is represented more than once in the normalized execution graph.',
          type: ValidationErrorType.duplicateId,
          stepId: stepId,
          loopId: loopId,
        ),
      );
    }
  }

  bool _sameStringList(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  void _validateRequiredFields(WorkflowDefinition definition, List<ValidationError> errors) {
    if (definition.name.isEmpty) {
      errors.add(
        const ValidationError(message: 'Workflow name must not be empty.', type: ValidationErrorType.missingField),
      );
    }
    if (definition.description.isEmpty) {
      errors.add(
        const ValidationError(
          message: 'Workflow description must not be empty.',
          type: ValidationErrorType.missingField,
        ),
      );
    }
    if (definition.steps.isEmpty) {
      errors.add(
        const ValidationError(message: 'Workflow must have at least one step.', type: ValidationErrorType.missingField),
      );
    }
    for (final step in definition.steps) {
      if (step.id.isEmpty) {
        errors.add(
          const ValidationError(
            message: 'Step must have a non-empty id.',
            type: ValidationErrorType.missingField,
            stepId: '<empty>',
          ),
        );
      }
      if (step.name.isEmpty) {
        errors.add(
          ValidationError(
            message: 'Step "${step.id}" must have a non-empty name.',
            type: ValidationErrorType.missingField,
            stepId: step.id,
          ),
        );
      }
      // Prompt is optional when skill is present (S04) or when the step type is
      // bash, approval, foreach, or loop (these types own their execution semantics
      // and orchestrate child steps rather than issuing prompts themselves).
      final isBashOrApproval = step.type == 'bash' || step.type == 'approval';
      final isForeachOrLoop = step.type == 'foreach' || step.type == 'loop';
      if (step.skill == null &&
          (step.prompts == null || step.prompts!.isEmpty) &&
          !isBashOrApproval &&
          !isForeachOrLoop) {
        errors.add(
          ValidationError(
            message: 'Step "${step.id}" must have at least one prompt.',
            type: ValidationErrorType.missingField,
            stepId: step.id,
          ),
        );
      } else if (step.prompts != null) {
        for (final p in step.prompts!) {
          if (p.isEmpty) {
            errors.add(
              ValidationError(
                message: 'Step "${step.id}" has an empty prompt — all prompts must be non-empty.',
                type: ValidationErrorType.missingField,
                stepId: step.id,
              ),
            );
            break;
          }
        }
      }
    }
  }

  void _validateUniqueStepIds(WorkflowDefinition definition, List<ValidationError> errors) {
    final seen = <String>{};
    for (final step in definition.steps) {
      if (!seen.add(step.id)) {
        errors.add(
          ValidationError(
            message: 'Duplicate step id "${step.id}".',
            type: ValidationErrorType.duplicateId,
            stepId: step.id,
          ),
        );
      }
    }
  }

  void _validateUniqueLoopIds(WorkflowDefinition definition, List<ValidationError> errors) {
    final seen = <String>{};
    for (final loop in definition.loops) {
      if (!seen.add(loop.id)) {
        errors.add(
          ValidationError(
            message: 'Duplicate loop id "${loop.id}".',
            type: ValidationErrorType.duplicateId,
            loopId: loop.id,
          ),
        );
      }
    }
  }
  void _validateLoopReferences(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();
    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        if (!stepIds.contains(stepId)) {
          errors.add(
            ValidationError(
              message: 'Loop "${loop.id}" references non-existent step "$stepId".',
              type: ValidationErrorType.invalidReference,
              loopId: loop.id,
            ),
          );
        }
      }
    }
  }

  void _validateLoopMaxIterations(WorkflowDefinition definition, List<ValidationError> errors) {
    for (final loop in definition.loops) {
      if (loop.maxIterations <= 0) {
        errors.add(
          ValidationError(
            message: 'Loop "${loop.id}" must have maxIterations > 0 (got ${loop.maxIterations}).',
            type: ValidationErrorType.missingMaxIterations,
            loopId: loop.id,
          ),
        );
      }
    }
  }

  void _validateLoopStepOverlap(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepToLoop = <String, String>{};
    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        if (stepToLoop.containsKey(stepId)) {
          errors.add(
            ValidationError(
              message: 'Step "$stepId" appears in multiple loops: "${stepToLoop[stepId]}" and "${loop.id}".',
              type: ValidationErrorType.loopOverlap,
              loopId: loop.id,
            ),
          );
        } else {
          stepToLoop[stepId] = loop.id;
        }
      }
    }
  }

  void _validateLoopFinalizers(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();
    for (final loop in definition.loops) {
      final finallyStep = loop.finally_;
      if (finallyStep == null) continue;

      if (!stepIds.contains(finallyStep)) {
        errors.add(
          ValidationError(
            message: 'Loop "${loop.id}" finalizer "$finallyStep" references a non-existent step.',
            type: ValidationErrorType.invalidReference,
            loopId: loop.id,
          ),
        );
      } else if (loop.steps.contains(finallyStep)) {
        errors.add(
          ValidationError(
            message:
                'Loop "${loop.id}" finalizer "$finallyStep" must not be one of the loop\'s '
                'iteration steps.',
            type: ValidationErrorType.loopOverlap,
            loopId: loop.id,
          ),
        );
      }
    }
  }

  void _validateStepDefaults(WorkflowDefinition definition) {
    final defaults = definition.stepDefaults;
    if (defaults == null || defaults.isEmpty) return;
    final stepIds = definition.steps.map((s) => s.id).toList();
    for (final d in defaults) {
      final matches = stepIds.any((id) => globMatchStepId(d.match, id));
      if (!matches) {
        WorkflowDefinitionValidator._log.warning(
          'stepDefaults pattern "${d.match}" does not match any step in '
          '"${definition.name}". Pattern may be targeting future steps.',
        );
      }
    }
  }

}
