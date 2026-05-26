part of '../workflow_definition_validator.dart';

extension _WorkflowReferenceRules on WorkflowDefinitionValidator {
  void _validateSkillReferences(WorkflowDefinition definition, List<ValidationError> errors) {
    if (skillRegistry == null) return;

    for (final step in definition.steps) {
      if (step.skill == null) continue;

      final resolvedStep = resolveStepConfig(step, definition.stepDefaults, roleDefaults: roleDefaults);
      final effectiveProvider = resolvedStep.provider;
      final error = skillRegistry!.validateRef(step.skill!, provider: effectiveProvider);
      if (error != null) {
        errors.add(_refErr(step.id, 'Step "${step.id}": $error'));
        continue; // Skip harness checks if skill doesn't exist.
      }

      final stepProvider = effectiveProvider;
      if (stepProvider != null) {
        // Explicit provider: hard error if skill not native for that harness.
        if (!stepProvider.startsWith('@') && !skillRegistry!.isNativeFor(step.skill!, stepProvider)) {
          final resolvedSkill = skillRegistry!.resolveRef(step.skill!, stepProvider);
          final available = resolvedSkill?.skill.nativeHarnesses.join(', ') ?? 'none';
          final searched = resolvedSkill?.invocationName ?? step.skill!;
          errors.add(
            _refErr(
              step.id,
              'Step "${step.id}": skill "${step.skill}" not available '
              'for provider "$stepProvider" (searched "$searched"). '
              'Skill is native for: $available. '
              'Install it in the provider\'s skill directory or remove the '
              'explicit provider.',
            ),
          );
        }
      }

      if (step.provider == null || workflowRoleDefaultAliases.contains(step.provider)) {
        // Default provider: warn if skill only found in one harness.
        final skill = effectiveProvider == null
            ? skillRegistry!.getByName(step.skill!)
            : skillRegistry!.resolveRef(step.skill!, effectiveProvider)?.skill;
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
          errors.add(_refErr(null, 'Workflow project field references undeclared variable "{{$ref}}".'));
        }
      }
      _validateWorkflowSystemReferences(definition.project!, errors, location: 'Workflow project field');
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
      for (final prompt in step.prompts ?? const <String>[]) {
        _validateWorkflowSystemReferences(prompt, errors, stepId: step.id, location: 'Step "${step.id}" prompt');
      }
      _validateStepWorkflowSystemReferences(step, errors);
      for (final ref in allPromptRefs) {
        if (!declaredVars.contains(ref)) {
          errors.add(_refErr(step.id, 'Step "${step.id}" prompt references undeclared variable "{{$ref}}".'));
        }
      }
      for (final name in step.workflowVariables) {
        if (!declaredVars.contains(name)) {
          errors.add(
            _refErr(
              step.id,
              'Step "${step.id}" declares workflowVariables entry "$name" '
              'but the workflow has no top-level variable with that name.',
            ),
          );
        }
      }
    }
    final gitStrategy = definition.gitStrategy;
    if (gitStrategy != null) {
      _validateGitStrategyWorkflowSystemReferences(gitStrategy, errors);
    }
  }

  void _validateStepWorkflowSystemReferences(WorkflowStep step, List<ValidationError> errors) {
    final workdir = step.workdir;
    if (workdir != null) {
      _validateWorkflowSystemReferences(workdir, errors, stepId: step.id, location: 'Step "${step.id}" workdir');
    }
    final maxParallel = step.maxParallel;
    if (maxParallel is String) {
      _validateWorkflowSystemReferences(
        maxParallel,
        errors,
        stepId: step.id,
        location: 'Step "${step.id}" maxParallel',
      );
    }
  }

  void _validateGitStrategyWorkflowSystemReferences(WorkflowGitStrategy strategy, List<ValidationError> errors) {
    final artifacts = strategy.artifacts;
    if (artifacts != null) {
      final project = artifacts.project;
      if (project != null) {
        _validateWorkflowSystemReferences(project, errors, location: 'gitStrategy.artifacts.project');
      }
      final commitMessage = artifacts.commitMessage;
      if (commitMessage != null) {
        _validateWorkflowSystemReferences(commitMessage, errors, location: 'gitStrategy.artifacts.commitMessage');
      }
    }

    final mount = strategy.worktree?.externalArtifactMount;
    if (mount != null) {
      _validateWorkflowSystemReferences(
        mount.fromProject,
        errors,
        location: 'gitStrategy.worktree.externalArtifactMount.fromProject',
      );
      final source = mount.source;
      if (source != null) {
        _validateWorkflowSystemReferences(
          source,
          errors,
          location: 'gitStrategy.worktree.externalArtifactMount.source',
        );
      }
    }
  }

  void _validateWorkflowSystemReferences(
    String template,
    List<ValidationError> errors, {
    String? stepId,
    required String location,
  }) {
    for (final ref in _engine.extractWorkflowSystemReferences(template)) {
      if (_engine.isKnownWorkflowSystemVariable(ref)) continue;
      errors.add(
        _refErr(
          stepId,
          '$location references unknown workflow system variable "{{$ref}}". '
          'Known workflow system variables: ${_engine.knownWorkflowSystemVariablesDescription}.',
        ),
      );
    }
  }

  void _validateMapAliases(WorkflowDefinition definition, List<ValidationError> errors) {
    final declaredVars = definition.variables.keys.toSet();
    for (final step in definition.steps) {
      final alias = step.mapAlias;
      if (alias == null) continue;
      if (!step.isMapStep) {
        errors.add(
          _refErr(
            step.id,
            'Step "${step.id}": "as: $alias" is only valid on map/foreach controllers '
            '(steps that declare map_over).',
          ),
        );
      }
      if (declaredVars.contains(alias)) {
        errors.add(
          _refErr(
            step.id,
            'Step "${step.id}": "as: $alias" collides with a declared workflow variable '
            '(pick a different identifier).',
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
            _contextErr(
              step.id,
              'Step "${step.id}" reads context key "$input" but no preceding step declares it as an output.',
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
            _contextErr(
              step.id,
              'Step "${step.id}" mapOver references "$mapOver" but no prior step '
              'declares it as a contextOutput.',
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
