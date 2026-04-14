import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:logging/logging.dart';

import 'schema_presets.dart' show schemaPresets;
import 'skill_registry.dart';
import 'step_config_resolver.dart' show globMatchStepId;
import 'workflow_template_engine.dart';

/// Classification of validation errors.
enum ValidationErrorType {
  missingField,
  duplicateId,
  invalidReference,
  invalidGate,
  missingMaxIterations,
  contextInconsistency,
  loopOverlap,
  unsupportedProviderCapability,
  hybridStepConstraint,
}

/// A structured validation error with category and location.
class ValidationError {
  final String message;
  final ValidationErrorType type;
  final String? stepId;
  final String? loopId;

  const ValidationError({required this.message, required this.type, this.stepId, this.loopId});

  @override
  String toString() =>
      '[$type'
      '${stepId != null ? ' step=$stepId' : ''}'
      '${loopId != null ? ' loop=$loopId' : ''}] $message';
}

/// The result of validating a [WorkflowDefinition].
///
/// [errors] are hard failures that prevent the definition from loading.
/// [warnings] are soft notices that do not prevent loading but may indicate
/// forward-compatibility issues or non-standard configurations.
///
/// A definition is considered valid (loadable) when [errors] is empty,
/// regardless of whether [warnings] is empty.
class ValidationReport {
  /// Hard validation failures that prevent loading.
  final List<ValidationError> errors;

  /// Soft notices that do not prevent loading.
  final List<ValidationError> warnings;

  const ValidationReport({required this.errors, required this.warnings});

  /// Whether there are no errors and no warnings.
  bool get isEmpty => errors.isEmpty && warnings.isEmpty;

  /// Whether there are no errors (definition is loadable).
  bool get hasErrors => errors.isNotEmpty;

  /// Whether there are any warnings.
  bool get hasWarnings => warnings.isNotEmpty;
}

/// Validates a [WorkflowDefinition] for semantic correctness.
///
/// Returns a [ValidationReport] with separate [errors] (hard failures) and
/// [warnings] (soft notices). A definition is valid when [errors] is empty.
class WorkflowDefinitionValidator {
  static final _log = Logger('WorkflowDefinitionValidator');
  static final _gateConditionPattern = RegExp(r'^([\w-]+)\.([\w-]+)\s*(==|!=|<=|>=|<|>)\s*(.+)$');
  final _engine = WorkflowTemplateEngine();

  /// Step types known by the engine. Any other type produces a warning.
  static const _knownTypes = {'research', 'analysis', 'writing', 'coding', 'automation', 'custom', 'bash', 'approval'};

  /// Optional skill registry for skill-aware validation.
  ///
  /// When null, skill reference validation is skipped (e.g. in tests or
  /// parsing-only contexts where no registry is configured).
  SkillRegistry? skillRegistry;

  /// Validates [definition] and returns a [ValidationReport].
  ///
  /// [continuityProviders]: optional set of provider names that support session
  /// continuity (e.g. `{'claude'}`). When provided, steps with
  /// [WorkflowStep.continueSession] targeting other providers produce an error.
  /// When null, this check is skipped.
  ValidationReport validate(WorkflowDefinition definition, {Set<String>? continuityProviders}) {
    final errors = <ValidationError>[];
    final warnings = <ValidationError>[];
    _validateRequiredFields(definition, errors);
    _validateUniqueStepIds(definition, errors);
    _validateUniqueLoopIds(definition, errors);
    _validateNormalizedNodes(definition, errors);
    _validateVariableReferences(definition, errors);
    _validateContextKeyConsistency(definition, errors);
    _validateGateExpressions(definition, errors);
    _validateLoopReferences(definition, errors);
    _validateLoopMaxIterations(definition, errors);
    _validateLoopStepOverlap(definition, errors);
    _validateLoopFinalizers(definition, errors);
    _validateStepDefaults(definition);
    _validateOutputConfigs(definition, errors);
    _validateMapOverReferences(definition, errors);
    _validateMapStepConstraints(definition, errors);
    if (continuityProviders != null) {
      _validateMultiPromptProviders(definition, errors, continuityProviders);
    }
    _validateSkillReferences(definition, errors);
    _validateHybridStepRules(definition, errors, warnings, continuityProviders);
    return ValidationReport(errors: errors, warnings: warnings);
  }

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

      // Harness compatibility check.
      final stepProvider = step.provider;
      if (stepProvider != null) {
        // Explicit provider: hard error if skill not native for that harness.
        if (!skillRegistry!.isNativeFor(step.skill!, stepProvider)) {
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
      } else {
        // Default provider: warn if skill only found in one harness.
        final skill = skillRegistry!.getByName(step.skill!);
        if (skill != null && skill.nativeHarnesses.length == 1) {
          _log.warning(
            'Step "${step.id}": skill "${step.skill}" found only in '
            '${skill.nativeHarnesses.first} harness. If the default provider '
            'changes, the skill may not be available.',
          );
        }
      }
    }
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
      // bash or approval (S02/S03 own execution semantics for those types).
      final isBashOrApproval = step.type == 'bash' || step.type == 'approval';
      if (step.skill == null && (step.prompts == null || step.prompts!.isEmpty) && !isBashOrApproval) {
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

  void _validateVariableReferences(WorkflowDefinition definition, List<ValidationError> errors) {
    final declaredVars = definition.variables.keys.toSet();
    for (final step in definition.steps) {
      // Extract variable references from all prompts combined (prompts optional for skill steps).
      final allPromptRefs = <String>{
        for (final p in step.prompts ?? const <String>[]) ..._engine.extractVariableReferences(p),
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
        final projectRefs = _engine.extractVariableReferences(step.project!);
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
              loopProduced.addAll(loopStep.contextOutputs);
            }
          }
        }
      }

      for (final input in step.contextInputs) {
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
      producedSoFar.addAll(step.contextOutputs);
    }
  }

  void _validateGateExpressions(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();

    for (final step in definition.steps) {
      if (step.gate == null) continue;
      final conditions = step.gate!.split('&&').map((c) => c.trim());
      for (final condition in conditions) {
        final match = _gateConditionPattern.firstMatch(condition);
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
        final referencedStepId = match.group(1)!;
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
        _log.warning(
          'stepDefaults pattern "${d.match}" does not match any step in '
          '"${definition.name}". Pattern may be targeting future steps.',
        );
      }
    }
  }

  void _validateOutputConfigs(WorkflowDefinition definition, List<ValidationError> errors) {
    for (final step in definition.steps) {
      if (step.outputs == null) continue;

      for (final entry in step.outputs!.entries) {
        final key = entry.key;
        final config = entry.value;

        // Output key must be in contextOutputs.
        if (!step.contextOutputs.contains(key)) {
          errors.add(
            ValidationError(
              message: 'Step "${step.id}" output "$key" is not declared in contextOutputs.',
              type: ValidationErrorType.contextInconsistency,
              stepId: step.id,
            ),
          );
        }

        // Schema preset name must be known.
        if (config.presetName != null) {
          if (!schemaPresets.containsKey(config.presetName)) {
            errors.add(
              ValidationError(
                message: 'Step "${step.id}" output "$key" references unknown schema preset "${config.presetName}".',
                type: ValidationErrorType.invalidReference,
                stepId: step.id,
              ),
            );
          }
        }

        // Inline schema must be an object with 'type'.
        if (config.inlineSchema != null) {
          if (!config.inlineSchema!.containsKey('type')) {
            errors.add(
              ValidationError(
                message: 'Step "${step.id}" output "$key" inline schema missing "type" field.',
                type: ValidationErrorType.missingField,
                stepId: step.id,
              ),
            );
          }
        }
      }
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
      producedSoFar.addAll(step.contextOutputs);
    }
  }

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

      // Warn when a map step has no contextOutputs — results will be discarded.
      if (step.contextOutputs.isEmpty) {
        _log.warning('Map step "${step.id}" has no contextOutputs; results will not be stored in context.');
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
      if (!_knownTypes.contains(step.type)) {
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
        if (continuityProviders != null) {
          final provider = step.provider ?? targetStep?.provider;
          if (provider != null && !continuityProviders.contains(provider)) {
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
