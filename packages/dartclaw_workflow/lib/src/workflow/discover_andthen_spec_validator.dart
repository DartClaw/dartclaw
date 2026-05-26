import 'fis_path_validation.dart';
import 'step_output_validation_helpers.dart';
import 'workflow_runner_types.dart';

DiscoverAndthenSpecValidation validateDiscoverAndthenSpecOutputs(
  Map<String, dynamic> outputs, {
  required String feature,
  required String? activeWorkspaceRoot,
}) {
  final source = trimmedString(outputs['spec_source']);
  if (source != 'existing' && source != 'synthesized') {
    return (
      outputs: outputs,
      validationFailure: StepValidationFailure(
        reason: 'Detect spec input produced invalid `spec_source`: ${source ?? '<empty>'}.',
      ),
    );
  }

  final rawSpecPath = stringValue(outputs['spec_path']).trim();
  if (source == 'synthesized') {
    return _validateSynthesized(outputs, feature, rawSpecPath, activeWorkspaceRoot);
  }
  return _validateExisting(outputs, feature, rawSpecPath, activeWorkspaceRoot);
}

DiscoverAndthenSpecValidation _validateSynthesized(
  Map<String, dynamic> outputs,
  String feature,
  String rawSpecPath,
  String? activeWorkspaceRoot,
) {
  final existingFeature = existingFisFeaturePath(feature, activeWorkspaceRoot);
  final existingFeatureFailure = existingFeature.validationFailure;
  if (existingFeatureFailure != null) return (outputs: outputs, validationFailure: existingFeatureFailure);
  if (existingFeature.path != null) {
    return (
      outputs: outputs,
      validationFailure: StepValidationFailure(
        reason:
            'Detect spec input misclassified existing FIS FEATURE as synthesized: ${existingFeature.path}. '
            'Expected `spec_source: existing` with matching `spec_path`.',
      ),
    );
  }
  if (rawSpecPath.isNotEmpty) {
    return (
      outputs: outputs,
      validationFailure: const StepValidationFailure(
        reason: 'Detect spec input produced `spec_source: synthesized` with a non-empty `spec_path`.',
      ),
    );
  }
  return (outputs: outputs, validationFailure: null);
}

DiscoverAndthenSpecValidation _validateExisting(
  Map<String, dynamic> outputs,
  String feature,
  String rawSpecPath,
  String? activeWorkspaceRoot,
) {
  if (rawSpecPath.isEmpty) {
    return (
      outputs: outputs,
      validationFailure: const StepValidationFailure(
        reason: 'Detect spec input produced `spec_source: existing` without a `spec_path`.',
      ),
    );
  }

  final specPath = safeFisPath(rawSpecPath, activeWorkspaceRoot, fieldName: 'spec_path');
  final featurePath = safeFisPath(feature, activeWorkspaceRoot, fieldName: 'FEATURE');
  if (specPath.validationFailure != null) return (outputs: outputs, validationFailure: specPath.validationFailure);
  if (featurePath.validationFailure != null) {
    return (outputs: outputs, validationFailure: featurePath.validationFailure);
  }
  if (specPath.path != featurePath.path) {
    return (
      outputs: outputs,
      validationFailure: StepValidationFailure(
        reason:
            'Detect spec input `spec_path` must match FEATURE exactly after normalization: '
            '${specPath.path} != ${featurePath.path}.',
      ),
    );
  }

  final fileFailure = validateExistingFisFile(specPath.path!, activeWorkspaceRoot, featureFieldName: 'spec_path');
  if (fileFailure != null) return (outputs: outputs, validationFailure: fileFailure);
  return (outputs: {...outputs, 'spec_path': specPath.path}, validationFailure: null);
}
