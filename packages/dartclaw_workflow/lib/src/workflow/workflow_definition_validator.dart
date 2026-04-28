import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:logging/logging.dart';

import 'schema_presets.dart' show schemaPresets;
import 'skill_registry.dart';
import 'step_config_resolver.dart'
    show WorkflowRoleDefaults, globMatchStepId, resolveStepConfig, workflowRoleDefaultAliases;
import 'workflow_context.dart';
import 'workflow_template_engine.dart';

part 'validation/workflow_structure_rules.dart';
part 'validation/workflow_reference_rules.dart';
part 'validation/workflow_gate_rules.dart';
part 'validation/workflow_output_schema_rules.dart';
part 'validation/workflow_git_strategy_rules.dart';
part 'validation/workflow_step_type_rules.dart';

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

  bool get isEmpty => errors.isEmpty && warnings.isEmpty;

  /// Whether there are no errors (definition is loadable).
  bool get hasErrors => errors.isNotEmpty;

  bool get hasWarnings => warnings.isNotEmpty;
}

/// Static analysis over the [WorkflowDefinition] AST.
///
/// Each rule group validates one axis of the definition; the composer
/// accumulates errors and warnings in a single [ValidationReport].
class WorkflowDefinitionValidator {
  static final _log = Logger('WorkflowDefinitionValidator');
  static final _gateConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)+)\s*(==|!=|<=|>=|<|>)\s*(.+)$');
  // `entryGate` supports bare keys and dotted context paths
  // (e.g. `active_prd != null`, `project_index.active_prd == null`, or
  // `review-prd.findings_count > 0`), mirroring how `GateEvaluator` resolves
  // exact flat keys before nested map paths.
  static final _entryGateConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s*(==|!=|<=|>=|<|>)\s*(.+)$');

  static const _artifactProducingSkills = {'dartclaw-prd', 'dartclaw-plan', 'dartclaw-spec'};
  static const _semanticStepTypes = {'coding', 'analysis', 'research', 'writing'};
  final _engine = WorkflowTemplateEngine();
  final WorkflowRoleDefaults roleDefaults;

  WorkflowDefinitionValidator({this.roleDefaults = const WorkflowRoleDefaults()});

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
    _validateProviderAliases(definition, errors);
    _validateVariableReferences(definition, errors);
    _validateDeprecationWarnings(definition, warnings);
    _validateContextKeyConsistency(definition, errors);
    _validateGateExpressions(definition, errors);
    _validateLoopGateExpressions(definition, errors);
    _validateLoopReferences(definition, errors);
    _validateLoopMaxIterations(definition, errors);
    _validateLoopStepOverlap(definition, errors);
    _validateLoopFinalizers(definition, errors);
    _validateStepDefaults(definition, errors);
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
}
