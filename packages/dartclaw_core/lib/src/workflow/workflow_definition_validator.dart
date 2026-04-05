import 'package:dartclaw_models/dartclaw_models.dart';

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
  final _engine = WorkflowTemplateEngine();

  /// Validates [definition] and returns all errors found.
  List<ValidationError> validate(WorkflowDefinition definition) {
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
    return errors;
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
          ValidationError(
            message: 'Step must have a non-empty id.',
            type: ValidationErrorType.missingField,
            stepId: step.id.isEmpty ? '<empty>' : step.id,
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
      if (step.prompt.isEmpty) {
        errors.add(
          ValidationError(
            message: 'Step "${step.id}" must have a non-empty prompt.',
            type: ValidationErrorType.missingField,
            stepId: step.id,
          ),
        );
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
      final refs = _engine.extractVariableReferences(step.prompt);
      for (final ref in refs) {
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
    // Pattern: stepId.key operator value (with && between conditions).
    // Step IDs may contain hyphens (e.g. "gap-analysis"), so use [\w-]+ for the ID part.
    final conditionPattern = RegExp(
      r'^([\w-]+)\.([\w-]+)\s*(==|!=|<=|>=|<|>)\s*(.+)$',
    );

    for (final step in definition.steps) {
      if (step.gate == null) continue;
      final conditions = step.gate!.split('&&').map((c) => c.trim());
      for (final condition in conditions) {
        final match = conditionPattern.firstMatch(condition);
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
}
