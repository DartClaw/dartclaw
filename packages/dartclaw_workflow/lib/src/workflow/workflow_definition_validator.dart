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
  static final _gateConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)+)\s*(==|!=|<=|>=|<|>)\s*(.+)$');
  // `entryGate` supports both bare-key and dotted `stepId.key` forms
  // (e.g. `active_prd != null` or `review-prd.findings_count > 0`), mirroring
  // how `GateEvaluator` reads values out of context. The key segment pattern
  // intentionally rejects multi-dotted forms (`a.b.c`) because the runtime
  // evaluator does not resolve nested paths — a gate written that way would
  // always read as null at runtime.
  static final _entryGateConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s*(==|!=|<=|>=|<|>)\s*(.+)$');

  /// Skills that produce artifact files under `context.docs_project_index.artifact_locations.*`.
  static const _artifactProducingSkills = {'dartclaw-prd', 'dartclaw-plan', 'dartclaw-spec'};
  final _engine = WorkflowTemplateEngine();

  /// Step types known by the engine. Any other type produces a warning.
  static const _knownTypes = {
    'research',
    'analysis',
    'writing',
    'coding',
    'automation',
    'custom',
    'bash',
    'approval',
    'foreach',
    'loop',
  };

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
    _validateMapAliases(definition, errors);
    _validateVariableReferences(definition, errors);
    _validateContextKeyConsistency(definition, errors);
    _validateGateExpressions(definition, errors);
    _validateLoopGateExpressions(definition, errors);
    _validateLoopReferences(definition, errors);
    _validateLoopMaxIterations(definition, errors);
    _validateLoopStepOverlap(definition, errors);
    _validateLoopFinalizers(definition, errors);
    _validateStepDefaults(definition);
    _validateGitStrategy(definition, errors, warnings);
    _validateStepDefaultsOrdering(definition, warnings);
    _validateStepEntryGates(definition, errors);
    _validateOutputConfigs(definition, errors, warnings);
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

  void _validateGitStrategy(
    WorkflowDefinition definition,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    final strategy = definition.gitStrategy;
    if (strategy == null) return;

    const worktreeValues = {'shared', 'per-task', 'per-map-item', 'inline', 'auto'};
    const promotionValues = {'merge', 'rebase', 'none'};

    final worktree = strategy.worktreeMode;
    if (worktree != null && !worktreeValues.contains(worktree)) {
      errors.add(
        ValidationError(
          message:
              'gitStrategy.worktree must be one of ${worktreeValues.join(', ')}; '
              'received "$worktree".',
          type: ValidationErrorType.invalidReference,
        ),
      );
    }

    final promotion = strategy.promotion;
    if (promotion != null && !promotionValues.contains(promotion)) {
      errors.add(
        ValidationError(
          message:
              'gitStrategy.promotion must be one of ${promotionValues.join(', ')}; '
              'received "$promotion".',
          type: ValidationErrorType.invalidReference,
        ),
      );
    }

    // Artifact-producing step detection — a step is artifact-producing if its
    // skill is on the known artifact-producer list, or if its contextOutputs
    // reference `artifact_locations.*` / a path-shaped artifact output.
    final hasArtifactProducer = definition.steps.any((step) {
      if (step.skill != null && _artifactProducingSkills.contains(step.skill)) return true;
      return step.contextOutputs.any(
        (k) =>
            k == 'prd' ||
            k == 'plan' ||
            k == 'story_spec' ||
            k == 'spec_path' ||
            k == 'story_specs' ||
            k == 'technical_research',
      );
    });

    final artifacts = strategy.artifacts;
    // gitStrategy.artifacts.commit defaulting truth table:
    //   - ≥1 artifact-producing step → default commit=true; commit=false with
    //     worktree=per-map-item is a hard error; commit=false with shared is
    //     allowed but warned.
    //   - No artifact-producing step → default commit=false; any explicit
    //     value is accepted silently.
    if (hasArtifactProducer) {
      final commitExplicit = artifacts?.commit;
      final resolvedArtifactWorktreeMode = _resolvedWorktreeModeForValidation(definition, strategy);
      if (commitExplicit == false && resolvedArtifactWorktreeMode == 'per-map-item') {
        errors.add(
          ValidationError(
            message:
                'gitStrategy.artifacts.commit: false is incompatible with '
                'gitStrategy.worktree: per-map-item when the workflow contains '
                'artifact-producing steps — worktrees cannot inherit uncommitted '
                'generated artifacts. Set artifacts.commit: true or change the '
                'worktree strategy.',
            type: ValidationErrorType.invalidReference,
          ),
        );
      } else if (commitExplicit == false && resolvedArtifactWorktreeMode == 'shared') {
        warnings.add(
          ValidationError(
            message:
                'gitStrategy.artifacts.commit: false with worktree: shared is '
                'allowed but uncommitted artifacts will not persist beyond the '
                'workflow branch trace; consider enabling commit.',
            type: ValidationErrorType.invalidReference,
          ),
        );
      }
    }

    if (strategy.legacyExternalArtifactMountLocation) {
      errors.add(
        ValidationError(
          message:
              'gitStrategy.externalArtifactMount was moved to '
              'gitStrategy.worktree.externalArtifactMount. Update the workflow '
              'to nest the block under gitStrategy.worktree.',
          type: ValidationErrorType.invalidReference,
        ),
      );
    }

    final mount = strategy.externalArtifactMount;
    if (mount != null) {
      const allowedModes = {'per-story-copy', 'bind-mount'};
      if (!allowedModes.contains(mount.mode)) {
        errors.add(
          ValidationError(
            message:
                'gitStrategy.externalArtifactMount.mode must be one of '
                '${allowedModes.join(', ')}; received "${mount.mode}".',
            type: ValidationErrorType.invalidReference,
          ),
        );
      }
      if (mount.mode == 'per-story-copy' && (mount.source == null || mount.source!.trim().isEmpty)) {
        errors.add(
          ValidationError(
            message:
                'gitStrategy.externalArtifactMount.source is required when mode '
                'is "per-story-copy" (a template resolved per map iteration, '
                'e.g. "{{map.item.spec_path}}").',
            type: ValidationErrorType.invalidReference,
          ),
        );
      }
      if (mount.mode == 'bind-mount') {
        if (mount.fromPath == null || mount.fromPath!.trim().isEmpty) {
          errors.add(
            ValidationError(
              message:
                  'gitStrategy.externalArtifactMount.fromPath is required when '
                  'mode is "bind-mount".',
              type: ValidationErrorType.invalidReference,
            ),
          );
        }
        warnings.add(
          ValidationError(
            message:
                'gitStrategy.externalArtifactMount.mode: "bind-mount" broadens '
                'the sandbox scope of each per-story worktree beyond its own '
                'FIS. Ensure the profile README justifies this opt-in.',
            type: ValidationErrorType.invalidReference,
          ),
        );
      }
    }
  }

  String _resolvedWorktreeModeForValidation(WorkflowDefinition definition, WorkflowGitStrategy strategy) {
    final authored = strategy.worktreeMode?.trim();
    if (authored != null && authored.isNotEmpty && authored != 'auto') {
      return authored;
    }

    final mapLikeSteps = definition.steps.where((step) => step.mapOver != null);
    if (mapLikeSteps.isEmpty) {
      return strategy.effectiveWorktreeMode(maxParallel: 1, isMap: false);
    }

    for (final step in mapLikeSteps) {
      final maxParallel = _staticMaxParallel(step.maxParallel);
      if (maxParallel == null || maxParallel > 1) {
        return strategy.effectiveWorktreeMode(maxParallel: 2, isMap: true);
      }
    }

    return strategy.effectiveWorktreeMode(maxParallel: 1, isMap: true);
  }

  int? _staticMaxParallel(Object? value) {
    if (value == null) return 1;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return 1;
      return int.tryParse(trimmed);
    }
    return null;
  }

  void _validateStepDefaultsOrdering(WorkflowDefinition definition, List<ValidationError> warnings) {
    final defaults = definition.stepDefaults;
    if (defaults == null || defaults.length < 2) return;

    final seen = <String>{};
    for (final step in definition.steps) {
      final matches = <String>[];
      for (var i = 0; i < defaults.length; i++) {
        final current = defaults[i];
        if (current.match == '*') continue; // intentional catch-all; too noisy to warn on

        if (globMatchStepId(current.match, step.id)) {
          matches.add(current.match);
          continue;
        }

        final isLiteral = !current.match.contains('*');
        if (!isLiteral || !_literalTokenMatch(current.match, step.id)) continue;

        for (var j = i + 1; j < defaults.length; j++) {
          final later = defaults[j];
          if (later.match == '*') continue;
          if (globMatchStepId(later.match, step.id)) {
            matches.add(current.match);
            matches.add(later.match);
            break;
          }
        }
      }
      if (matches.length < 2) continue;

      final key = '${step.id}\x00${matches.join("\x00")}';
      if (!seen.add(key)) continue;
      warnings.add(
        ValidationError(
          message:
              'Info: stepDefaults ordering is load-bearing for step "${step.id}" — '
              'multiple patterns match (${matches.join(', ')}). The first match '
              'wins, so reordering or glob widening can change which provider/model applies.',
          type: ValidationErrorType.invalidReference,
          stepId: step.id,
        ),
      );
    }
  }

  bool _literalTokenMatch(String literal, String stepId) {
    if (literal.isEmpty) return false;
    return stepId.endsWith('-$literal') ||
        stepId.contains('-$literal-') ||
        stepId.endsWith('_$literal') ||
        stepId.contains('_${literal}_');
  }

  void _validateStepEntryGates(WorkflowDefinition definition, List<ValidationError> errors) {
    for (final step in definition.steps) {
      final expression = step.entryGate;
      if (expression == null || expression.trim().isEmpty) continue;
      final conditions = expression.split('&&').map((c) => c.trim());
      for (final condition in conditions) {
        if (!_entryGateConditionPattern.hasMatch(condition)) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" has invalid entryGate expression: "$condition". '
                  'Expected: "<key> <operator> <value>" (e.g. '
                  '"prd_source == synthesized" or "review.findings_count > 0").',
              type: ValidationErrorType.invalidGate,
              stepId: step.id,
            ),
          );
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
        for (final p in step.prompts ?? const <String>[])
          ..._engine.extractVariableReferences(p, mapAliases: aliases),
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

  /// Validates the `as:` loop variable name on map/foreach controllers.
  ///
  /// Parser enforces shape and reserved names (`map` / `context`); the
  /// validator owns cross-field rules: `as:` only applies to map controllers,
  /// and must not collide with a declared workflow variable.
  void _validateMapAliases(WorkflowDefinition definition, List<ValidationError> errors) {
    final declaredVars = definition.variables.keys.toSet();
    for (final step in definition.steps) {
      final alias = step.mapAlias;
      if (alias == null) continue;
      if (!step.isMapStep) {
        errors.add(
          ValidationError(
            message: 'Step "${step.id}": "as: $alias" is only valid on map/foreach controllers '
                '(steps that declare map_over).',
            type: ValidationErrorType.invalidReference,
            stepId: step.id,
          ),
        );
      }
      if (declaredVars.contains(alias)) {
        errors.add(
          ValidationError(
            message: 'Step "${step.id}": "as: $alias" collides with a declared workflow variable '
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
        final referencedStepId = _gateReferencedStepId(match.group(1)!);
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

  void _validateLoopGateExpressions(WorkflowDefinition definition, List<ValidationError> errors) {
    final stepIds = definition.steps.map((s) => s.id).toSet();

    for (final loop in definition.loops) {
      final gates = {'entryGate': loop.entryGate, 'exitGate': loop.exitGate};
      for (final gateEntry in gates.entries) {
        final expression = gateEntry.value;
        if (expression == null || expression.trim().isEmpty) continue;

        final conditions = expression.split('&&').map((c) => c.trim());
        for (final condition in conditions) {
          final match = _gateConditionPattern.firstMatch(condition);
          if (match == null) {
            errors.add(
              ValidationError(
                message:
                    'Loop "${loop.id}" has invalid ${gateEntry.key} expression: "$condition". '
                    'Expected: stepId.key operator value.',
                type: ValidationErrorType.invalidGate,
                loopId: loop.id,
              ),
            );
            continue;
          }

          final referencedStepId = _gateReferencedStepId(match.group(1)!);
          if (!stepIds.contains(referencedStepId)) {
            errors.add(
              ValidationError(
                message: 'Loop "${loop.id}" ${gateEntry.key} references non-existent step "$referencedStepId".',
                type: ValidationErrorType.invalidReference,
                loopId: loop.id,
              ),
            );
          }
        }
      }
    }
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

  void _validateOutputConfigs(
    WorkflowDefinition definition,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    final descriptionsByOutput = <String, List<(String, String)>>{};

    for (final step in definition.steps) {
      if (step.outputs == null) continue;

      for (final entry in step.outputs!.entries) {
        final key = entry.key;
        final config = entry.value;
        final description = config.description?.trim();
        if (description != null && description.isNotEmpty) {
          descriptionsByOutput.putIfAbsent(key, () => <(String, String)>[]).add((step.id, description));
        }

        // Non-null but whitespace-only description is always an authoring
        // mistake — either provide content or omit the key.
        if (config.description != null && config.description!.trim().isEmpty) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" output "$key" has a blank "description" — '
                  'provide content or remove the key.',
              type: ValidationErrorType.missingField,
              stepId: step.id,
            ),
          );
        }

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
          final preset = schemaPresets[config.presetName];
          if (preset == null) {
            errors.add(
              ValidationError(
                message: 'Step "${step.id}" output "$key" references unknown schema preset "${config.presetName}".',
                type: ValidationErrorType.invalidReference,
                stepId: step.id,
              ),
            );
          } else if (preset.description != null &&
              preset.description!.trim().isNotEmpty &&
              config.description != null &&
              config.description!.trim().isNotEmpty) {
            // Both preset and YAML define a description — the inline one wins,
            // defeating the point of referencing the preset. Warn the author
            // so they can drop one or the other intentionally.
            warnings.add(
              ValidationError(
                message:
                    'Step "${step.id}" output "$key" sets both an inline "description" and '
                    'references preset "${config.presetName}" which already provides one. '
                    'The inline description overrides the preset — drop one to avoid drift.',
                type: ValidationErrorType.contextInconsistency,
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

        if (config.format == OutputFormat.json && !config.hasSchema) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" output "$key": format: json requires a schema '
                  '(preset name or inline schema).',
              type: ValidationErrorType.missingField,
              stepId: step.id,
            ),
          );
        }

        if (config.outputMode == OutputMode.structured) {
          if (config.format != OutputFormat.json) {
            errors.add(
              ValidationError(
                message:
                    'Step "${step.id}" output "$key" uses outputMode: structured but format is '
                    '"${config.format.name}". Structured output requires format: json.',
                type: ValidationErrorType.contextInconsistency,
                stepId: step.id,
              ),
            );
          }
          if (!config.hasSchema) {
            errors.add(
              ValidationError(
                message:
                    'Step "${step.id}" output "$key" uses outputMode: structured but has no schema. '
                    'Structured output requires a schema preset or inline schema.',
                type: ValidationErrorType.missingField,
                stepId: step.id,
              ),
            );
          }
          final inlineSchema = config.inlineSchema;
          if (inlineSchema != null) {
            final violations = <String>[];
            _collectStructuredSchemaViolations(inlineSchema, path: key, violations: violations);
            for (final violation in violations) {
              errors.add(
                ValidationError(
                  message: 'Step "${step.id}" output "$key" inline schema $violation',
                  type: ValidationErrorType.contextInconsistency,
                  stepId: step.id,
                ),
              );
            }
          }
        }
      }
    }

    for (final entry in descriptionsByOutput.entries) {
      final uniqueDescriptions = entry.value.map((item) => item.$2).toSet();
      if (uniqueDescriptions.length < 2) continue;
      final producers = entry.value.map((item) => item.$1).join(', ');
      warnings.add(
        ValidationError(
          message:
              'Output "${entry.key}" is produced by multiple steps with different descriptions '
              '($producers). The first producer wins in context-summary rendering.',
          type: ValidationErrorType.contextInconsistency,
        ),
      );
    }
  }

  void _collectStructuredSchemaViolations(
    Map<String, dynamic> schema, {
    required String path,
    required List<String> violations,
  }) {
    final type = schema['type'];
    if (type == 'object') {
      final additionalProperties = schema['additionalProperties'];
      if (additionalProperties != false) {
        violations.add('at "$path" must set additionalProperties: false.');
      }
      final properties = schema['properties'];
      if (properties is Map<String, dynamic>) {
        for (final entry in properties.entries) {
          final child = entry.value;
          if (child is Map<String, dynamic>) {
            _collectStructuredSchemaViolations(child, path: '$path.${entry.key}', violations: violations);
          }
        }
      }
    } else if (type == 'array') {
      final items = schema['items'];
      if (items is Map<String, dynamic>) {
        _collectStructuredSchemaViolations(items, path: '$path[]', violations: violations);
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
