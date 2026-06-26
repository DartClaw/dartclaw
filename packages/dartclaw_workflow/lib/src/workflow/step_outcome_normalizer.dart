import 'story_spec_output_validator.dart';
import 'workflow_runner_types.dart';

export 'story_spec_output_validator.dart' show validateStorySpecOutputs;

/// Context needed by pure step-output normalization.
final class StepOutputNormalizationContext {
  final String planDir;
  final String? activeWorkspaceRoot;

  const StepOutputNormalizationContext({this.planDir = '', this.activeWorkspaceRoot});
}

/// Normalizes output envelopes and returns a typed handoff.
StepHandoff normalizeOutputs(Map<String, dynamic> envelope, StepOutputNormalizationContext context) {
  final normalized = validateStorySpecOutputs(
    envelope,
    planDir: context.planDir,
    activeWorkspaceRoot: context.activeWorkspaceRoot,
  );
  final failure = normalized.validationFailure;
  if (failure != null) {
    return StepHandoffValidationFailed(outputs: const {}, validationFailure: failure);
  }
  return StepHandoffSuccess(outputs: Map<String, Object?>.from(normalized.outputs));
}
