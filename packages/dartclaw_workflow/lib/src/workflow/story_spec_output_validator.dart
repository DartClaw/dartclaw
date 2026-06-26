import 'dart:io';

import 'package:path/path.dart' as p;

import 'produced_artifact_resolver.dart';
import 'story_specs_contract_validator.dart';
import 'workflow_runner_types.dart';

StorySpecOutputValidation validateStorySpecOutputs(
  Map<String, dynamic> outputs, {
  String planDir = '',
  String? activeWorkspaceRoot,
}) {
  if (!outputs.containsKey('story_specs')) {
    return (outputs: outputs, validationFailure: null);
  }

  final contract = validateStorySpecsContract(outputs['story_specs']);
  final contractFailure = contract.validationFailure;
  if (contractFailure != null) {
    return (outputs: outputs, validationFailure: contractFailure);
  }

  final normalizedOutputs = {...outputs, 'story_specs': contract.storySpecs!};
  final StorySpecPathResolution resolution;
  try {
    resolution = resolveStorySpecPaths(normalizedOutputs, planDir: planDir, projectRoot: activeWorkspaceRoot);
  } on FormatException catch (e) {
    return (outputs: outputs, validationFailure: StepValidationFailure(reason: e.message));
  }
  final missingSpecPaths = <String>[];
  for (final specPath in resolution.specPaths) {
    if (!_storySpecPathExists(specPath, activeWorkspaceRoot: activeWorkspaceRoot)) {
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
        'per story record. On retry, create those files before emitting '
        'their paths or emit only spec_path values for files that already exist.',
    missingArtifacts: sorted,
  );
}

bool _storySpecPathExists(String specPath, {required String? activeWorkspaceRoot}) {
  if (activeWorkspaceRoot == null || activeWorkspaceRoot.isEmpty) return true;
  final candidate = p.isAbsolute(specPath) ? File(specPath) : File(p.join(activeWorkspaceRoot, specPath));
  return candidate.existsSync();
}
