import 'dart:io';

import 'package:path/path.dart' as p;

import 'produced_artifact_resolver.dart';
import 'workflow_runner_types.dart';

/// Context needed by pure step-output normalization.
final class StepOutputNormalizationContext {
  final String planDir;
  final String? projectRoot;

  const StepOutputNormalizationContext({this.planDir = '', this.projectRoot});
}

/// Normalizes output envelopes and returns a typed handoff.
StepHandoff normalizeOutputs(Map<String, dynamic> envelope, StepOutputNormalizationContext context) {
  final normalized = validateStorySpecOutputs(envelope, planDir: context.planDir, projectRoot: context.projectRoot);
  final failure = normalized.validationFailure;
  if (failure != null) {
    return StepHandoffValidationFailed(outputs: const {}, validationFailure: failure);
  }
  return StepHandoffSuccess(outputs: Map<String, Object?>.from(normalized.outputs));
}

/// Normalizes `story_specs` paths and reports missing referenced files.
StorySpecOutputValidation validateStorySpecOutputs(
  Map<String, dynamic> outputs, {
  String planDir = '',
  String? projectRoot,
}) {
  if (!outputs.containsKey('story_specs')) {
    return (outputs: outputs, validationFailure: null);
  }

  final resolution = resolveStorySpecPaths(outputs, planDir: planDir);
  final missingSpecPaths = <String>[];
  for (final specPath in resolution.specPaths) {
    if (!_storySpecPathExists(specPath, projectRoot: projectRoot)) {
      missingSpecPaths.add(specPath);
    }
  }
  return (outputs: resolution.outputs, validationFailure: _missingStorySpecFailure(missingSpecPaths));
}

StepValidationFailure? _missingStorySpecFailure(List<String> missingSpecPaths) {
  if (missingSpecPaths.isEmpty) return null;
  final sorted = missingSpecPaths.toList()..sort();
  return StepValidationFailure(
    reason:
        'Plan skill produced story_specs.spec_path values that do not '
        'exist on disk: $sorted. Expected the skill to write a FIS file '
        'per story record.',
    missingArtifacts: sorted,
  );
}

bool _storySpecPathExists(String specPath, {required String? projectRoot}) {
  if (projectRoot == null || projectRoot.isEmpty) return true;
  final candidate = p.isAbsolute(specPath) ? File(specPath) : File(p.join(projectRoot, specPath));
  return candidate.existsSync();
}
