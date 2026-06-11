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
            errors.add(_refErr(stepId, 'Normalized action node references unknown step "$stepId".'));
            continue;
          }
          if (step.isMapStep) {
            errors.add(_contextErr(stepId, 'Step "$stepId" is map-backed but was normalized as an action node.'));
          }
          if (step.parallel) {
            errors.add(_contextErr(stepId, 'Step "$stepId" is parallel but was normalized as an action node.'));
          }
          _recordNormalizedStep(stepId, seenStepIds, errors);

        case MapNode(stepId: final stepId):
          final step = stepById[stepId];
          if (step == null) {
            errors.add(_refErr(stepId, 'Normalized map node references unknown step "$stepId".'));
            continue;
          }
          if (!step.isMapStep) {
            errors.add(_contextErr(stepId, 'Step "$stepId" is not a map step but was normalized as a map node.'));
          }
          _recordNormalizedStep(stepId, seenStepIds, errors);

        case ParallelGroupNode(stepIds: final stepIds):
          if (stepIds.isEmpty) {
            errors.add(
              _err(ValidationErrorType.missingField, 'Normalized parallel group must contain at least one step.'),
            );
            continue;
          }
          for (final stepId in stepIds) {
            final step = stepById[stepId];
            if (step == null) {
              errors.add(_refErr(stepId, 'Normalized parallel group references unknown step "$stepId".'));
              continue;
            }
            if (!step.parallel) {
              errors.add(
                _contextErr(stepId, 'Parallel group step "$stepId" is missing parallel:true in the authored step.'),
              );
            }
            if (step.isMapStep) {
              errors.add(_contextErr(stepId, 'Parallel group step "$stepId" cannot also be a map step.'));
            }
            _recordNormalizedStep(stepId, seenStepIds, errors);
          }

        case LoopNode(loopId: final loopId, stepIds: final stepIds, finallyStepId: final finallyStepId):
          final loop = loopById[loopId];
          if (loop == null) {
            errors.add(
              _err(
                ValidationErrorType.invalidReference,
                'Normalized loop node references unknown loop "$loopId".',
                loopId: loopId,
              ),
            );
            continue;
          }
          if (!_sameStringList(loop.steps, stepIds)) {
            errors.add(
              _err(
                ValidationErrorType.contextInconsistency,
                'Loop "$loopId" node step order does not match the authored loop body.',
                loopId: loopId,
              ),
            );
          }
          if (loop.finally_ != finallyStepId) {
            errors.add(
              _err(
                ValidationErrorType.contextInconsistency,
                'Loop "$loopId" node finalizer does not match the authored loop finalizer.',
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
                _err(
                  ValidationErrorType.invalidReference,
                  'Loop "$loopId" node references unknown step "$stepId".',
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
              _refErr(
                controllerStepId,
                'Normalized foreach node references unknown controller step "$controllerStepId".',
              ),
            );
            continue;
          }
          if (!controllerStep.isForeachController) {
            errors.add(
              _contextErr(
                controllerStepId,
                'Step "$controllerStepId" is not a foreach controller but was normalized as a foreach node.',
              ),
            );
          }
          if (childStepIds.isEmpty) {
            errors.add(
              _err(
                ValidationErrorType.missingField,
                'Foreach node "$controllerStepId" must have at least one child step.',
                stepId: controllerStepId,
              ),
            );
          }
          _recordNormalizedStep(controllerStepId, seenStepIds, errors);
          for (final childStepId in childStepIds) {
            if (!stepById.containsKey(childStepId)) {
              errors.add(
                _refErr(childStepId, 'Foreach "$controllerStepId" references unknown child step "$childStepId".'),
              );
              continue;
            }
            _recordNormalizedStep(childStepId, seenStepIds, errors);
            // A foreach-nested loop's controller appears as a child step; its
            // body (and finalizer) steps are owned by the loop and are not
            // emitted as separate nodes, so account for them here.
            final nestedLoop = loopById[childStepId];
            if (nestedLoop != null) {
              for (final loopStepId in nestedLoop.steps) {
                if (!stepById.containsKey(loopStepId)) {
                  errors.add(
                    _err(
                      ValidationErrorType.invalidReference,
                      'Foreach-nested loop "$childStepId" references unknown step "$loopStepId".',
                      stepId: loopStepId,
                      loopId: childStepId,
                    ),
                  );
                  continue;
                }
                _recordNormalizedStep(loopStepId, seenStepIds, errors, loopId: childStepId);
              }
              final finalizer = nestedLoop.finally_;
              if (finalizer != null && stepById.containsKey(finalizer)) {
                _recordNormalizedStep(finalizer, seenStepIds, errors, loopId: childStepId);
              }
            }
          }
      }
    }

    for (final step in definition.steps) {
      if (!seenStepIds.contains(step.id)) {
        errors.add(_contextErr(step.id, 'Step "${step.id}" is not represented in the normalized execution graph.'));
      }
    }
  }

  void _recordNormalizedStep(String stepId, Set<String> seenStepIds, List<ValidationError> errors, {String? loopId}) {
    if (!seenStepIds.add(stepId)) {
      errors.add(
        _err(
          ValidationErrorType.duplicateId,
          'Step "$stepId" is represented more than once in the normalized execution graph.',
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
      errors.add(_err(ValidationErrorType.missingField, 'Workflow name must not be empty.'));
    }
    if (definition.description.isEmpty) {
      errors.add(_err(ValidationErrorType.missingField, 'Workflow description must not be empty.'));
    }
    if (definition.steps.isEmpty) {
      errors.add(_err(ValidationErrorType.missingField, 'Workflow must have at least one step.'));
    }
    for (final step in definition.steps) {
      if (step.id.isEmpty) {
        errors.add(_err(ValidationErrorType.missingField, 'Step must have a non-empty id.', stepId: '<empty>'));
      }
      if (step.name.isEmpty) {
        errors.add(
          _err(ValidationErrorType.missingField, 'Step "${step.id}" must have a non-empty name.', stepId: step.id),
        );
      }
      // Prompt is optional when skill is present or when the step type owns
      // host-side execution semantics rather than issuing prompts itself.
      final isBashOrApproval = step.taskType == WorkflowTaskType.bash || step.taskType == WorkflowTaskType.approval;
      final isForeachOrLoop = step.taskType == WorkflowTaskType.foreach || step.taskType == WorkflowTaskType.loop;
      final isAggregateReviews = step.taskType == WorkflowTaskType.aggregateReviews;
      if (step.skill == null &&
          (step.prompts == null || step.prompts!.isEmpty) &&
          !isBashOrApproval &&
          !isForeachOrLoop &&
          !isAggregateReviews) {
        errors.add(
          _err(ValidationErrorType.missingField, 'Step "${step.id}" must have at least one prompt.', stepId: step.id),
        );
      } else if (step.prompts != null) {
        for (final p in step.prompts!) {
          if (p.isEmpty) {
            errors.add(
              _err(
                ValidationErrorType.missingField,
                'Step "${step.id}" has an empty prompt — all prompts must be non-empty.',
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
        errors.add(_err(ValidationErrorType.duplicateId, 'Duplicate step id "${step.id}".', stepId: step.id));
      }
    }
  }

  void _validateUniqueLoopIds(WorkflowDefinition definition, List<ValidationError> errors) {
    final seen = <String>{};
    for (final loop in definition.loops) {
      if (!seen.add(loop.id)) {
        errors.add(_err(ValidationErrorType.duplicateId, 'Duplicate loop id "${loop.id}".', loopId: loop.id));
      }
    }
  }

  void _validateLoopReferences(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();
    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        if (!stepIds.contains(stepId)) {
          errors.add(
            _err(
              ValidationErrorType.invalidReference,
              'Loop "${loop.id}" references non-existent step "$stepId".',
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
          _err(
            ValidationErrorType.missingMaxIterations,
            'Loop "${loop.id}" must have maxIterations > 0 (got ${loop.maxIterations}).',
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
            _err(
              ValidationErrorType.loopOverlap,
              'Step "$stepId" appears in multiple loops: "${stepToLoop[stepId]}" and "${loop.id}".',
              loopId: loop.id,
            ),
          );
        } else {
          stepToLoop[stepId] = loop.id;
        }
      }
    }
  }

  void _validateAggregateReviewsPlacement(WorkflowDefinition definition, List<ValidationError> errors) {
    final aggregatorIds = {
      for (final step in definition.steps)
        if (step.taskType == WorkflowTaskType.aggregateReviews) step.id,
    };
    if (aggregatorIds.isEmpty) return;

    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        if (aggregatorIds.contains(stepId)) {
          errors.add(
            _err(
              ValidationErrorType.invalidReference,
              'Aggregate-reviews step "$stepId" must not appear inside loop "${loop.id}": its reserved '
              'unscoped outputs ({review_findings, findings_count, gating_findings_count}) are meant to be '
              'written once per fan-out, and re-execution would overwrite them each iteration. Sources whose '
              'own report-path output collides with the unscoped "review_findings" key would also see the '
              'previous merge fed back in as source content.',
              stepId: stepId,
              loopId: loop.id,
            ),
          );
        }
      }
    }

    for (final step in definition.steps) {
      if (step.foreachSteps == null) continue;
      for (final childId in step.foreachSteps!) {
        if (aggregatorIds.contains(childId)) {
          errors.add(
            _err(
              ValidationErrorType.invalidReference,
              'Aggregate-reviews step "$childId" must not appear inside foreach step "${step.id}": its '
              'reserved unscoped outputs ({review_findings, findings_count, gating_findings_count}) are meant '
              'to be written once per fan-out, and per-iteration re-execution would overwrite them. Sources '
              'whose own report-path output collides with the unscoped "review_findings" key would also see '
              'the previous merge fed back in as source content.',
              stepId: childId,
            ),
          );
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
          _err(
            ValidationErrorType.invalidReference,
            'Loop "${loop.id}" finalizer "$finallyStep" references a non-existent step.',
            loopId: loop.id,
          ),
        );
      } else if (loop.steps.contains(finallyStep)) {
        errors.add(
          _err(
            ValidationErrorType.loopOverlap,
            'Loop "${loop.id}" finalizer "$finallyStep" must not be one of the loop\'s '
            'iteration steps.',
            loopId: loop.id,
          ),
        );
      }
    }
  }

  void _validateProviderAliases(WorkflowDefinition definition, List<ValidationError> errors) {
    for (final step in definition.steps) {
      final provider = step.provider;
      if (provider == null || !provider.startsWith('@') || workflowRoleDefaultAliases.contains(provider)) continue;
      errors.add(
        _err(
          ValidationErrorType.invalidReference,
          'Step "${step.id}": provider "$provider" is not a known role alias. '
          'Supported aliases: ${workflowRoleDefaultAliases.join(', ')}.',
          stepId: step.id,
        ),
      );
    }
  }

  void _validateStepDefaults(WorkflowDefinition definition, List<ValidationError> errors) {
    final defaults = definition.stepDefaults;
    if (defaults == null || defaults.isEmpty) return;
    final stepIds = definition.steps.map((s) => s.id).toList();
    for (final d in defaults) {
      final provider = d.provider;
      if (provider != null && provider.startsWith('@') && !workflowRoleDefaultAliases.contains(provider)) {
        final matchingStepIds = stepIds.where((id) => globMatchStepId(d.match, id)).toList();
        final matchingSteps = matchingStepIds.isEmpty ? 'no current steps' : matchingStepIds.join(', ');
        errors.add(
          _err(
            ValidationErrorType.invalidReference,
            'stepDefaults pattern "${d.match}" uses provider "$provider", '
            'which is not a known role alias. Supported aliases: ${workflowRoleDefaultAliases.join(', ')}. '
            'Matching steps: $matchingSteps.',
          ),
        );
      }

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
