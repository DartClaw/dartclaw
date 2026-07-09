import 'workflow_definition.dart';
import 'package:logging/logging.dart';

import 'workflow_artifact_committer.dart' show workflowHasArtifactProducer;
import 'output_resolver.dart' show FileSystemOutput;
import 'schema_presets.dart' show isReviewReportPathPreset, schemaPresets;
import 'schema_validator.dart' show SchemaValidator;
import 'workflow_output_contract.dart'
    show executionEnvelopeOutputsKey, executionEnvelopeStepOutcomeKey, reservedEnvelopeOutputKeys;
import 'step_config_resolver.dart'
    show WorkflowRoleDefaults, globMatchStepId, resolveStepConfig, workflowRoleDefaultAliases;
import 'workflow_template_engine.dart';

part 'validation/workflow_validation_helpers.dart';
part 'validation/workflow_structure_rules.dart';
part 'validation/workflow_reference_rules.dart';
part 'validation/workflow_gate_rules.dart';
part 'validation/workflow_output_schema_rules.dart';
part 'validation/workflow_git_strategy_rules.dart';
part 'validation/workflow_step_type_rules.dart';
part 'validation/workflow_codex_allowed_tools_rules.dart';
part 'validation/workflow_loop_policy_rules.dart';
part 'validation/workflow_review_source_prefix_rules.dart';

/// Classification of validation errors.
enum ValidationErrorType {
  missingField,
  duplicateId,
  invalidReference,
  invalidGate,
  missingMaxIterations,
  invalidLoopPolicy,
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
  // Gates support bare keys and dotted context paths, mirroring how
  // `GateEvaluator` resolves exact flat keys before nested map paths.
  static final _gateConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s*(==|!=|<=|>=|<|>)\s*([^<>=!]+)$');
  static final _gateUnaryConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s+(isEmpty|isNotEmpty)$');
  static final _entryGateConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s*(==|!=|<=|>=|<|>)\s*([^<>=!]+)$');
  static final _entryGateUnaryConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s+(isEmpty|isNotEmpty)$');

  final WorkflowTemplateEngine _engine;
  final WorkflowRoleDefaults roleDefaults;

  WorkflowDefinitionValidator({
    this.roleDefaults = const WorkflowRoleDefaults(),
    WorkflowTemplateEngine? templateEngine,
  }) : _engine = templateEngine ?? WorkflowTemplateEngine();

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
    _validateContextKeyConsistency(definition, errors);
    _validateGateExpressions(definition, errors);
    _validateLoopGateExpressions(definition, errors);
    _validateLoopReferences(definition, errors);
    _validateLoopMaxIterations(definition, errors);
    _validateLoopStepOverlap(definition, errors);
    _validateLoopFinalizers(definition, errors);
    _validateLoopMaxIterationsPolicy(definition, errors);
    _validateStepDefaults(definition, errors);
    _validateGitStrategy(definition, errors, warnings);
    _validateStepDefaultsOrdering(definition, warnings);
    _validateStepEntryGates(definition, errors);
    _validateOutputConfigs(definition, errors, warnings);
    _warnCodexAllowedToolsPolicy(definition, warnings);
    _validateMapOverReferences(definition, errors);
    _validateMapStepConstraints(definition, errors);
    _validateAggregateReviewsConstraints(definition, errors);
    _validateAggregateReviewsPlacement(definition, errors);
    _validateReviewSourcePrefixing(definition, errors);
    if (continuityProviders != null) {
      _validateMultiPromptProviders(definition, errors, continuityProviders);
    }
    _validateHybridStepRules(definition, errors, warnings, continuityProviders);
    return ValidationReport(errors: errors, warnings: warnings);
  }
}
