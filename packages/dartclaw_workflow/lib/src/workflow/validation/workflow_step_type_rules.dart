part of '../workflow_definition_validator.dart';

bool _isFindingsCountPreset(String? presetName) => presetName == 'findings_count';

bool _isGatingFindingsCountPreset(String? presetName) => presetName == 'gating_findings_count';

extension _WorkflowStepTypeRules on WorkflowDefinitionValidator {
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
        errors.add(_contextErr(step.id, 'Map step "${step.id}" cannot also be a parallel step.'));
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
          _contextErr(
            step.id,
            'Map step "${step.id}" declares ${step.outputKeys.length} outputs keys '
            '(${step.outputKeys.join(', ')}); a map/foreach controller emits exactly one '
            'aggregate list value, so only one key is meaningful. Keep a single key — '
            'downstream steps can index the aggregate by iteration and child step id.',
          ),
        );
      }
    }
  }

  void _validateAggregateReviewsConstraints(WorkflowDefinition definition, List<ValidationError> errors) {
    final requiredAggregatorOutputs = <String, (OutputFormat, bool Function(String?))>{
      'review_report_path': (OutputFormat.path, isReviewReportPathPreset),
      'findings_count': (OutputFormat.json, _isFindingsCountPreset),
      'gating_findings_count': (OutputFormat.json, _isGatingFindingsCountPreset),
    };
    final priorSteps = <String, WorkflowStep>{};

    for (final step in definition.steps) {
      if (step.taskType != WorkflowTaskType.aggregateReviews) {
        priorSteps[step.id] = step;
        continue;
      }

      final aggregateReviews = step.aggregateReviews;
      if (aggregateReviews == null || aggregateReviews.isEmpty) {
        errors.add(
          _contextErr(
            step.id,
            'Aggregate-reviews step "${step.id}" must declare aggregateReviews with at least one upstream step id.',
          ),
        );
      }

      _validateAggregatorOutputShape(step, requiredAggregatorOutputs, errors);

      // Track report-path output keys seen across the listed sources so a
      // collision (last-writer-wins on context merge) is rejected at validation
      // rather than silently emitting the same section twice at runtime.
      final reportKeysBySource = <String, String>{};

      for (final sourceId in aggregateReviews ?? const <String>[]) {
        final sourceStep = priorSteps[sourceId];
        if (sourceStep == null) {
          final validPriorIds = priorSteps.keys.join(', ');
          errors.add(
            _refErr(
              step.id,
              'Aggregate-reviews step "${step.id}" references unknown or non-prior upstream step "$sourceId"; '
              'valid prior step ids: ${validPriorIds.isEmpty ? '<none>' : validPriorIds}.',
            ),
          );
          continue;
        }

        const scopedCountSuffixes = ['.findings_count', '.gating_findings_count'];
        final hasCountOutput = sourceStep.outputKeys.any(
          (key) => scopedCountSuffixes.any((suffix) => key == '$sourceId$suffix'),
        );
        if (!hasCountOutput) {
          errors.add(
            _contextErr(
              step.id,
              'Aggregate-reviews step "${step.id}" upstream step "$sourceId" must declare a source-scoped '
              '"$sourceId.findings_count" or "$sourceId.gating_findings_count" output; the aggregator runner '
              'only reads counts under the exact source id.',
            ),
          );
        }

        final reportOutputs = _reviewReportPathOutputs(sourceStep).toList(growable: false);
        if (reportOutputs.length != 1) {
          errors.add(
            _contextErr(
              step.id,
              'Aggregate-reviews step "${step.id}" upstream step "$sourceId" must declare exactly one '
              'review-report path output.',
            ),
          );
        }

        if (reportOutputs.length == 1) {
          final reportKey = reportOutputs.single.key;
          final priorSourceWithSameKey = reportKeysBySource.entries
              .where((entry) => entry.value == reportKey)
              .firstOrNull
              ?.key;
          if (priorSourceWithSameKey != null) {
            errors.add(
              _contextErr(
                step.id,
                'Aggregate-reviews step "${step.id}" sources "$priorSourceWithSameKey" and "$sourceId" both '
                'declare report-path output "$reportKey"; report-path output keys must be unique across the '
                'aggregated sources (otherwise the merged context drops one report).',
              ),
            );
          } else {
            reportKeysBySource[sourceId] = reportKey;
          }
        }
      }

      priorSteps[step.id] = step;
    }
  }

  void _validateAggregatorOutputShape(
    WorkflowStep step,
    Map<String, (OutputFormat, bool Function(String?))> requiredAggregatorOutputs,
    List<ValidationError> errors,
  ) {
    final outputKeys = step.outputKeys.toSet();
    if (outputKeys.length != requiredAggregatorOutputs.length ||
        !outputKeys.containsAll(requiredAggregatorOutputs.keys)) {
      errors.add(
        _contextErr(
          step.id,
          'Aggregate-reviews step "${step.id}" outputs must declare exactly '
          '{review_report_path, findings_count, gating_findings_count}.',
        ),
      );
      return;
    }

    final outputs = step.outputs ?? const <String, OutputConfig>{};
    for (final entry in requiredAggregatorOutputs.entries) {
      final config = outputs[entry.key];
      if (config == null) continue;
      final (expectedFormat, presetCheck) = entry.value;
      if (config.format != expectedFormat || !presetCheck(config.presetName)) {
        errors.add(
          _contextErr(
            step.id,
            'Aggregate-reviews step "${step.id}" output "${entry.key}" must be '
            'format: ${expectedFormat.name} with the matching schema preset '
            '(got format: ${config.format.name}, schema: ${config.presetName ?? '<none>'}).',
          ),
        );
      }
    }
  }

  Iterable<MapEntry<String, OutputConfig>> _reviewReportPathOutputs(WorkflowStep step) sync* {
    for (final entry in step.outputs?.entries ?? const Iterable<MapEntry<String, OutputConfig>>.empty()) {
      if (entry.value.format == OutputFormat.path && isReviewReportPathPreset(entry.value.presetName)) {
        yield entry;
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
      // Role aliases resolve at runtime to a concrete provider; the alias itself is never in the
      // `continuityProviders` set (which is built from `config.providers.entries.keys`).
      // The runtime fallback in `WorkflowExecutor._resolveContinueSessionProvider`
      // emits a warning and re-routes to the root provider when the resolved
      // alias differs from the root step's family, so we keep the safety net
      // without false-positiving aliased steps at validation time.
      if (provider.startsWith('@')) continue;
      if (!continuityProviders.contains(provider)) {
        errors.add(
          _err(
            ValidationErrorType.unsupportedProviderCapability,
            'Step "${step.id}" uses multi-prompt but targets provider "$provider" '
            'which does not support session continuity.',
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
      // Approval step in a loop — warning (runs fine today, requires loop exit gate to avoid infinite wait).
      if (step.taskType == WorkflowTaskType.approval && stepToLoop.containsKey(step.id)) {
        warnings.add(
          _err(
            ValidationErrorType.hybridStepConstraint,
            'Approval step "${step.id}" is inside loop "${stepToLoop[step.id]}". '
            'Approval steps in loops will pause the loop on every iteration — '
            'ensure the loop exit gate accounts for approval outcomes.',
            stepId: step.id,
          ),
        );
      }

      // Approval step as parallel — hard error (approval requires sequential gate behavior).
      if (step.taskType == WorkflowTaskType.approval && step.parallel) {
        errors.add(
          _err(
            ValidationErrorType.hybridStepConstraint,
            'Approval step "${step.id}" cannot be a parallel step. '
            'Approval gates require sequential execution.',
            stepId: step.id,
          ),
        );
      }

      if ((step.taskType == WorkflowTaskType.bash || step.taskType == WorkflowTaskType.approval) &&
          step.isMultiPrompt) {
        errors.add(
          _err(
            ValidationErrorType.hybridStepConstraint,
            'Step "${step.id}" is a "${step.taskType.toJson()}" step and cannot use a prompt list. '
            'Use a single prompt string${step.taskType == WorkflowTaskType.approval ? ' (or omit the prompt)' : ''}.',
            stepId: step.id,
          ),
        );
      }

      if (step.parallel && step.continueSession != null) {
        errors.add(
          _err(
            ValidationErrorType.hybridStepConstraint,
            'Step "${step.id}" cannot combine parallel execution with continueSession. '
            'Session continuity requires deterministic step ordering.',
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
        if (continuityProviders != null) {
          final provider = step.provider ?? targetStep?.provider;
          if (provider != null && !provider.startsWith('@') && !continuityProviders.contains(provider)) {
            errors.add(
              _err(
                ValidationErrorType.unsupportedProviderCapability,
                'Step "${step.id}" uses continueSession but targets provider "$provider" '
                'which does not support session continuity.',
                stepId: step.id,
              ),
            );
          }
        }

        if (targetStepId == null) {
          errors.add(
            _err(
              ValidationErrorType.hybridStepConstraint,
              'Step "${step.id}" uses continueSession but has no resolvable target step. '
              'The first step cannot continue a prior session.',
              stepId: step.id,
            ),
          );
          continue;
        }

        if (targetStep == null) {
          errors.add(
            _err(
              ValidationErrorType.hybridStepConstraint,
              'Step "${step.id}" uses continueSession but references unknown step "$targetStepId".',
              stepId: step.id,
            ),
          );
          continue;
        }

        // continueSession on a non-agent step — hard error (bash/approval steps have no session).
        if (step.taskType == WorkflowTaskType.bash || step.taskType == WorkflowTaskType.approval) {
          errors.add(
            _err(
              ValidationErrorType.hybridStepConstraint,
              'Step "${step.id}" uses continueSession but is a "${step.taskType.toJson()}" step. '
              'Only agent steps support session continuity.',
              stepId: step.id,
            ),
          );
        }

        final targetIndex = definition.steps.indexWhere((s) => s.id == targetStepId);
        if (targetIndex >= stepIndex) {
          errors.add(
            _err(
              ValidationErrorType.hybridStepConstraint,
              'Step "${step.id}" uses continueSession but references "$targetStepId" '
              'which does not precede it in the workflow.',
              stepId: step.id,
            ),
          );
          continue;
        }

        if (targetStep.taskType == WorkflowTaskType.bash || targetStep.taskType == WorkflowTaskType.approval) {
          errors.add(
            _err(
              ValidationErrorType.hybridStepConstraint,
              'Step "${step.id}" uses continueSession but the referenced step "$targetStepId" '
              'is a "${targetStep.taskType.toJson()}" step which has no session to continue.',
              stepId: step.id,
            ),
          );
        }

        final stepProvider = resolveStepConfig(step, definition.stepDefaults, roleDefaults: roleDefaults).provider;
        final targetProvider = resolveStepConfig(
          targetStep,
          definition.stepDefaults,
          roleDefaults: roleDefaults,
        ).provider;
        if (stepProvider != null && targetProvider != null && stepProvider != targetProvider) {
          errors.add(
            _err(
              ValidationErrorType.hybridStepConstraint,
              'continueSession: true on step "${step.id}" requires the same provider as the previous step '
              '"${targetStep.id}", but they resolve to "$stepProvider" and "$targetProvider" respectively. '
              'Either pin a matching provider explicitly or remove continueSession.',
              stepId: step.id,
            ),
          );
        }

        // continueSession crossing a loop boundary — hard error.
        final stepLoopId = stepToLoop[step.id];
        final targetLoopId = stepToLoop[targetStep.id];
        if (stepLoopId != targetLoopId) {
          errors.add(
            _err(
              ValidationErrorType.hybridStepConstraint,
              'Step "${step.id}" uses continueSession but crosses a loop boundary '
              '(step is ${stepLoopId != null ? 'in loop "$stepLoopId"' : 'outside a loop'}, '
              'target step "$targetStepId" is ${targetLoopId != null ? 'in loop "$targetLoopId"' : 'outside a loop'}). '
              'continueSession cannot span loop boundaries.',
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
            _err(
              ValidationErrorType.hybridStepConstraint,
              'Step "${step.id}" is part of a continueSession chain that forms a cycle via "$targetStepId".',
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
