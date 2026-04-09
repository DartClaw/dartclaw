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
}

/// A structured validation error with category and location.
class ValidationError {
  final String message;
  final ValidationErrorType type;
  final String? stepId;
  final String? loopId;

  const ValidationError({
    required this.message,
    required this.type,
    this.stepId,
    this.loopId,
  });

  @override
  String toString() =>
      '[$type'
      '${stepId != null ? ' step=$stepId' : ''}'
      '${loopId != null ? ' loop=$loopId' : ''}] $message';
}

/// Validates a [WorkflowDefinition] for semantic correctness.
///
/// Returns a list of validation errors. An empty list means the
/// definition is valid.
class WorkflowDefinitionValidator {
  static final _log = Logger('WorkflowDefinitionValidator');
  static final _gateConditionPattern = RegExp(
    r'^([\w-]+)\.([\w-]+)\s*(==|!=|<=|>=|<|>)\s*(.+)$',
  );
  final _engine = WorkflowTemplateEngine();

  /// Optional skill registry for skill-aware validation.
  ///
  /// When null, skill reference validation is skipped (e.g. in tests or
  /// parsing-only contexts where no registry is configured).
  SkillRegistry? skillRegistry;

  /// Validates [definition] and returns all errors found.
  ///
  /// [continuityProviders]: optional set of provider names that support session
  /// continuity (e.g. `{'claude'}`). When provided, multi-prompt steps targeting
  /// other providers produce a validation error. When null, this check is skipped.
  List<ValidationError> validate(
    WorkflowDefinition definition, {
    Set<String>? continuityProviders,
  }) {
    final errors = <ValidationError>[];
    _validateRequiredFields(definition, errors);
    _validateUniqueStepIds(definition, errors);
    _validateUniqueLoopIds(definition, errors);
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
    return errors;
  }

  void _validateSkillReferences(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
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
              message: 'Step "${step.id}": skill "${step.skill}" not available '
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

  void _validateRequiredFields(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
    if (definition.name.isEmpty) {
      errors.add(
        const ValidationError(
          message: 'Workflow name must not be empty.',
          type: ValidationErrorType.missingField,
        ),
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
        const ValidationError(
          message: 'Workflow must have at least one step.',
          type: ValidationErrorType.missingField,
        ),
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
      // Prompt is optional when skill is present (S04).
      if (step.skill == null && (step.prompts == null || step.prompts!.isEmpty)) {
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

  void _validateUniqueStepIds(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
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

  void _validateUniqueLoopIds(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
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

  void _validateVariableReferences(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
    final declaredVars = definition.variables.keys.toSet();
    for (final step in definition.steps) {
      // Extract variable references from all prompts combined (prompts optional for skill steps).
      final allPromptRefs = <String>{
        for (final p in step.prompts ?? const <String>[])
          ..._engine.extractVariableReferences(p),
      };
      for (final ref in allPromptRefs) {
        if (!declaredVars.contains(ref)) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" prompt references undeclared variable "{{$ref}}".',
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
                message:
                    'Step "${step.id}" project field references undeclared variable "{{$ref}}".',
                type: ValidationErrorType.invalidReference,
                stepId: step.id,
              ),
            );
          }
        }
      }
    }
  }

  void _validateContextKeyConsistency(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
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
              message:
                  'Step "${step.id}" reads context key "$input" but no preceding step declares it as an output.',
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

  void _validateGateExpressions(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
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
              message:
                  'Step "${step.id}" gate references non-existent step "$referencedStepId".',
              type: ValidationErrorType.invalidReference,
              stepId: step.id,
            ),
          );
        }
      }
    }
  }

  void _validateLoopReferences(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
    final stepIds = definition.steps.map((s) => s.id).toSet();
    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        if (!stepIds.contains(stepId)) {
          errors.add(
            ValidationError(
              message:
                  'Loop "${loop.id}" references non-existent step "$stepId".',
              type: ValidationErrorType.invalidReference,
              loopId: loop.id,
            ),
          );
        }
      }
    }
  }

  void _validateLoopMaxIterations(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
    for (final loop in definition.loops) {
      if (loop.maxIterations <= 0) {
        errors.add(
          ValidationError(
            message:
                'Loop "${loop.id}" must have maxIterations > 0 (got ${loop.maxIterations}).',
            type: ValidationErrorType.missingMaxIterations,
            loopId: loop.id,
          ),
        );
      }
    }
  }

  void _validateLoopStepOverlap(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
    final stepToLoop = <String, String>{};
    for (final loop in definition.loops) {
      for (final stepId in loop.steps) {
        if (stepToLoop.containsKey(stepId)) {
          errors.add(
            ValidationError(
              message:
                  'Step "$stepId" appears in multiple loops: "${stepToLoop[stepId]}" and "${loop.id}".',
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

  void _validateLoopFinalizers(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
    final stepIds = definition.steps.map((s) => s.id).toSet();
    for (final loop in definition.loops) {
      final finallyStep = loop.finally_;
      if (finallyStep == null) continue;

      if (!stepIds.contains(finallyStep)) {
        errors.add(
          ValidationError(
            message:
                'Loop "${loop.id}" finalizer "$finallyStep" references a non-existent step.',
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

  void _validateOutputConfigs(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
    for (final step in definition.steps) {
      if (step.outputs == null) continue;

      for (final entry in step.outputs!.entries) {
        final key = entry.key;
        final config = entry.value;

        // Output key must be in contextOutputs.
        if (!step.contextOutputs.contains(key)) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" output "$key" is not declared in contextOutputs.',
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
                message:
                    'Step "${step.id}" output "$key" references unknown schema preset "${config.presetName}".',
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
                message:
                    'Step "${step.id}" output "$key" inline schema missing "type" field.',
                type: ValidationErrorType.missingField,
                stepId: step.id,
              ),
            );
          }
        }
      }
    }
  }

  void _validateMapOverReferences(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
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

  void _validateMapStepConstraints(
    WorkflowDefinition definition,
    List<ValidationError> errors,
  ) {
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
        _log.warning(
          'Map step "${step.id}" has no contextOutputs; results will not be stored in context.',
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
}
