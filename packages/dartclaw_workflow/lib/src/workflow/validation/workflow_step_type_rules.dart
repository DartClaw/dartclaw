part of '../workflow_definition_validator.dart';

extension _WorkflowStepTypeRules on WorkflowDefinitionValidator {
  void _validateDeprecationWarnings(WorkflowDefinition definition, List<ValidationError> warnings) {
    final defaultVariables = {
      for (final entry in definition.variables.entries)
        if (entry.value.defaultValue != null) entry.key: entry.value.defaultValue!,
    };
    final comparisonContext = WorkflowContext(variables: defaultVariables);
    final workflowProject = definition.project;
    if (workflowProject != null) {
      final resolvedWorkflowProject = _resolveProjectTemplate(workflowProject, comparisonContext);
      for (final step in definition.steps) {
        final stepProject = step.project;
        if (stepProject == null) continue;
        final resolvedStepProject = _resolveProjectTemplate(stepProject, comparisonContext);
        final sameProject =
            stepProject.trim() == workflowProject.trim() ||
            (resolvedWorkflowProject != null &&
                resolvedStepProject != null &&
                resolvedWorkflowProject == resolvedStepProject);
        if (!sameProject) continue;
        warnings.add(
          ValidationError(
            message:
                'Step "${step.id}" declares a project that duplicates the workflow-level project binding. '
                'Remove the redundant step-level "project:" declaration.',
            type: ValidationErrorType.contextInconsistency,
            stepId: step.id,
          ),
        );
      }
    }

    final semanticSteps = definition.steps
        .where((step) => step.typeAuthored && WorkflowDefinitionValidator._semanticStepTypes.contains(step.type))
        .toList(growable: false);
    if (semanticSteps.isNotEmpty) {
      warnings.add(
        ValidationError(
          message:
              'Semantic step types (${semanticSteps.map((step) => '"${step.type}"').toSet().join(', ')}) are deprecated '
              'for workflow engine decisions and are retained as observability labels only.',
          type: ValidationErrorType.contextInconsistency,
          stepId: semanticSteps.first.id,
        ),
      );
    }
  }

  String? _resolveProjectTemplate(String template, WorkflowContext context) {
    try {
      final resolved = _engine.resolve(template, context).trim();
      return resolved.isEmpty ? null : resolved;
    } on ArgumentError {
      return null;
    }
  }

  /// Validates the `as:` loop variable name on map/foreach controllers.
  ///
  /// Parser enforces shape and reserved names (`map` / `context`); the
  /// validator owns cross-field rules: `as:` only applies to map controllers,
  /// and must not collide with a declared workflow variable.
  void _validateMapStepConstraints(WorkflowDefinition definition, List<ValidationError> errors) {
    for (final step in definition.steps) {
      if (step.mapOver == null) continue;

      // A map step cannot also be a parallel step.
      if (step.parallel) {
        errors.add(
          ValidationError(
            message: 'Map step "${step.id}" cannot also be a parallel step.',
            type: ValidationErrorType.contextInconsistency,
            stepId: step.id,
          ),
        );
      }

      // Warn when a map step has no outputs — results will be discarded.
      if (step.outputKeys.isEmpty) {
        WorkflowDefinitionValidator._log.warning(
          'Map step "${step.id}" has no outputs; results will not be stored in context.',
        );
      }

      // A map/foreach controller emits exactly one aggregate value — the list of
      // per-iteration results. Declaring more than one outputs key causes the
      // engine to broadcast the identical aggregate under every declared key,
      // which is almost certainly not what the author intended.
      if (step.outputKeys.length > 1) {
        errors.add(
          ValidationError(
            message:
                'Map step "${step.id}" declares ${step.outputKeys.length} outputs keys '
                '(${step.outputKeys.join(', ')}); a map/foreach controller emits exactly one '
                'aggregate list value, so only one key is meaningful. Keep a single key — '
                'downstream steps can index the aggregate by iteration and child step id.',
            type: ValidationErrorType.contextInconsistency,
            stepId: step.id,
          ),
        );
      }
    }
  }

  void _validateMultiPromptProviders(
    WorkflowDefinition definition,
    List<ValidationError> errors,
    Set<String> continuityProviders,
  ) {
    for (final step in definition.steps) {
      if (!step.isMultiPrompt) continue;
      final provider = step.provider;
      if (provider == null) continue; // No explicit provider — skip (default may support it).
      // Role aliases (`@executor`, `@reviewer`, `@planner`, `@workflow`, ...) resolve at
      // runtime to a concrete provider; the alias itself is never in the
      // `continuityProviders` set (which is built from `config.providers.entries.keys`).
      // The runtime fallback in `WorkflowExecutor._resolveContinueSessionProvider`
      // emits a warning and re-routes to the root provider when the resolved
      // alias differs from the root step's family, so we keep the safety net
      // without false-positiving aliased steps at validation time.
      // TODO(0.16.7+): full alias-resolution path — thread the workflow's
      // roles config through the validator so we can validate the resolved
      // concrete provider rather than skipping the check.
      if (provider.startsWith('@')) continue;
      if (!continuityProviders.contains(provider)) {
        errors.add(
          ValidationError(
            message:
                'Step "${step.id}" uses multi-prompt but targets provider "$provider" '
                'which does not support session continuity.',
            type: ValidationErrorType.unsupportedProviderCapability,
            stepId: step.id,
          ),
        );
      }
    }
  }

  void _validateHybridStepRules(
    WorkflowDefinition definition,
    List<ValidationError> errors,
    List<ValidationError> warnings,
    Set<String>? continuityProviders,
  ) {
    // Build loop membership maps.
    final stepToLoop = <String, String>{}; // stepId -> loopId
    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        stepToLoop[stepId] = loop.id;
      }
    }

    for (final step in definition.steps) {
      // Unknown step type — warning (forward-compatible authoring).
      if (!WorkflowDefinitionValidator._knownTypes.contains(step.type)) {
        warnings.add(
          ValidationError(
            message:
                'Step "${step.id}" uses unknown type "${step.type}". '
                'This may be a typo or a future step type. '
                'The step will be loaded but may not execute as expected.',
            type: ValidationErrorType.hybridStepConstraint,
            stepId: step.id,
          ),
        );
      }

      // Approval step in a loop — warning (runs fine today, requires loop exit gate to avoid infinite wait).
      if (step.type == 'approval' && stepToLoop.containsKey(step.id)) {
        warnings.add(
          ValidationError(
            message:
                'Approval step "${step.id}" is inside loop "${stepToLoop[step.id]}". '
                'Approval steps in loops will pause the loop on every iteration — '
                'ensure the loop exit gate accounts for approval outcomes.',
            type: ValidationErrorType.hybridStepConstraint,
            stepId: step.id,
          ),
        );
      }

      // Approval step as parallel — hard error (approval requires sequential gate behavior).
      if (step.type == 'approval' && step.parallel) {
        errors.add(
          ValidationError(
            message:
                'Approval step "${step.id}" cannot be a parallel step. '
                'Approval gates require sequential execution.',
            type: ValidationErrorType.hybridStepConstraint,
            stepId: step.id,
          ),
        );
      }

      if ((step.type == 'bash' || step.type == 'approval') && step.isMultiPrompt) {
        errors.add(
          ValidationError(
            message:
                'Step "${step.id}" is a "${step.type}" step and cannot use a prompt list. '
                'Use a single prompt string${step.type == 'approval' ? ' (or omit the prompt)' : ''}.',
            type: ValidationErrorType.hybridStepConstraint,
            stepId: step.id,
          ),
        );
      }

      if (step.parallel && step.continueSession != null) {
        errors.add(
          ValidationError(
            message:
                'Step "${step.id}" cannot combine parallel execution with continueSession. '
                'Session continuity requires deterministic step ordering.',
            type: ValidationErrorType.hybridStepConstraint,
            stepId: step.id,
          ),
        );
      }

      if (step.onError case final onError? when onError != 'pause' && onError != 'continue' && onError != 'fail') {
        warnings.add(
          ValidationError(
            message:
                'Step "${step.id}" uses unsupported onError value "$onError". '
                'Supported values are "pause", "continue", and legacy "fail". '
                'Unknown values currently behave like "pause".',
            type: ValidationErrorType.hybridStepConstraint,
            stepId: step.id,
          ),
        );
      }
      // continueSession validation.
      if (step.continueSession != null) {
        final stepIndex = definition.steps.indexWhere((s) => s.id == step.id);
        final targetStepId = _resolveContinueTargetStepId(definition, stepIndex, step);
        final targetStep = targetStepId != null ? _findStep(definition, targetStepId) : null;

        // continueSession with unsupported provider — hard error.
        // Role aliases (`@executor`, `@reviewer`, ...) resolve at runtime to
        // concrete providers and are never in the `continuityProviders` set,
        // so we skip the check for `@`-prefixed providers; the runtime
        // fallback in `WorkflowExecutor._resolveContinueSessionProvider`
        // covers the alias-mismatch safety net (re-routes to root provider
        // with a warning). See `_validateMultiPromptProviders` for the
        // mirrored skip and the `TODO(0.16.7+)` deferral note.
        if (continuityProviders != null) {
          final provider = step.provider ?? targetStep?.provider;
          if (provider != null && !provider.startsWith('@') && !continuityProviders.contains(provider)) {
            errors.add(
              ValidationError(
                message:
                    'Step "${step.id}" uses continueSession but targets provider "$provider" '
                    'which does not support session continuity.',
                type: ValidationErrorType.unsupportedProviderCapability,
                stepId: step.id,
              ),
            );
          }
        }

        if (targetStepId == null) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" uses continueSession but has no resolvable target step. '
                  'The first step cannot continue a prior session.',
              type: ValidationErrorType.hybridStepConstraint,
              stepId: step.id,
            ),
          );
          continue;
        }

        if (targetStep == null) {
          errors.add(
            ValidationError(
              message: 'Step "${step.id}" uses continueSession but references unknown step "$targetStepId".',
              type: ValidationErrorType.hybridStepConstraint,
              stepId: step.id,
            ),
          );
          continue;
        }

        // continueSession on a non-agent step — hard error (bash/approval steps have no session).
        if (step.type == 'bash' || step.type == 'approval') {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" uses continueSession but is a "${step.type}" step. '
                  'Only agent steps support session continuity.',
              type: ValidationErrorType.hybridStepConstraint,
              stepId: step.id,
            ),
          );
        }

        final targetIndex = definition.steps.indexWhere((s) => s.id == targetStepId);
        if (targetIndex >= stepIndex) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" uses continueSession but references "$targetStepId" '
                  'which does not precede it in the workflow.',
              type: ValidationErrorType.hybridStepConstraint,
              stepId: step.id,
            ),
          );
          continue;
        }

        if (targetStep.type == 'bash' || targetStep.type == 'approval') {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" uses continueSession but the referenced step "$targetStepId" '
                  'is a "${targetStep.type}" step which has no session to continue.',
              type: ValidationErrorType.hybridStepConstraint,
              stepId: step.id,
            ),
          );
        }

        // continueSession crossing a loop boundary — hard error.
        final stepLoopId = stepToLoop[step.id];
        final targetLoopId = stepToLoop[targetStep.id];
        if (stepLoopId != targetLoopId) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" uses continueSession but crosses a loop boundary '
                  '(step is ${stepLoopId != null ? 'in loop "$stepLoopId"' : 'outside a loop'}, '
                  'target step "$targetStepId" is ${targetLoopId != null ? 'in loop "$targetLoopId"' : 'outside a loop'}). '
                  'continueSession cannot span loop boundaries.',
              type: ValidationErrorType.hybridStepConstraint,
              stepId: step.id,
            ),
          );
        }
      }
    }

    for (var i = 0; i < definition.steps.length; i++) {
      final step = definition.steps[i];
      if (step.continueSession == null) continue;

      final visited = <String>{step.id};
      var currentIndex = i;
      var currentStep = step;

      while (currentStep.continueSession != null) {
        final targetStepId = _resolveContinueTargetStepId(definition, currentIndex, currentStep);
        if (targetStepId == null) break;
        if (!visited.add(targetStepId)) {
          errors.add(
            ValidationError(
              message: 'Step "${step.id}" is part of a continueSession chain that forms a cycle via "$targetStepId".',
              type: ValidationErrorType.hybridStepConstraint,
              stepId: step.id,
            ),
          );
          break;
        }
        final targetIndex = definition.steps.indexWhere((candidate) => candidate.id == targetStepId);
        if (targetIndex < 0) break;
        currentIndex = targetIndex;
        currentStep = definition.steps[targetIndex];
      }
    }
  }
}
