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

  final contract = _validateStorySpecsContract(outputs['story_specs']);
  final contractFailure = contract.validationFailure;
  if (contractFailure != null) {
    return (outputs: outputs, validationFailure: contractFailure);
  }

  final normalizedOutputs = {...outputs, 'story_specs': contract.storySpecs!};
  final resolution = resolveStorySpecPaths(normalizedOutputs, planDir: planDir);
  final missingSpecPaths = <String>[];
  for (final specPath in resolution.specPaths) {
    if (!_storySpecPathExists(specPath, projectRoot: projectRoot)) {
      missingSpecPaths.add(specPath);
    }
  }
  return (outputs: resolution.outputs, validationFailure: _missingStorySpecFailure(missingSpecPaths));
}

({Map<String, dynamic>? storySpecs, StepValidationFailure? validationFailure}) _validateStorySpecsContract(
  Object? rawStorySpecs,
) {
  if (rawStorySpecs is List) {
    return (
      storySpecs: null,
      validationFailure: const StepValidationFailure(
        reason:
            'Plan skill produced legacy list-shaped `story_specs`. Expected an object with an `items` list of '
            'records carrying `id`, `spec_path`, and `dependencies`.',
      ),
    );
  }

  final storySpecs = _asStringKeyedMap(rawStorySpecs);
  if (storySpecs == null) {
    return (
      storySpecs: null,
      validationFailure: const StepValidationFailure(
        reason: 'Plan skill produced invalid `story_specs`. Expected an object with an `items` list.',
      ),
    );
  }

  final rawItems = storySpecs['items'];
  if (rawItems is! List) {
    return (
      storySpecs: null,
      validationFailure: const StepValidationFailure(
        reason: 'Plan skill produced invalid `story_specs`. Expected `story_specs.items` to be a list.',
      ),
    );
  }

  final errors = <String>[];
  final normalizedItems = <Map<String, dynamic>>[];
  for (var index = 0; index < rawItems.length; index++) {
    final item = _asStringKeyedMap(rawItems[index]);
    if (item == null) {
      errors.add('story_specs.items[$index] must be an object.');
      continue;
    }

    final normalizedItem = Map<String, dynamic>.from(item);
    final id = _trimmedString(item['id']);
    if (id == null) {
      errors.add('story_specs.items[$index] is missing a non-empty `id`.');
    } else {
      normalizedItem['id'] = id;
    }

    final specPath = _trimmedString(item['spec_path']);
    if (specPath == null) {
      errors.add('story_specs.items[$index] is missing a non-empty `spec_path`.');
    } else {
      normalizedItem['spec_path'] = specPath;
    }

    final rawDependencies = item['dependencies'];
    if (rawDependencies is! List) {
      errors.add('story_specs.items[$index] is missing `dependencies` as a list.');
    } else {
      final dependencies = <String>[];
      for (var depIndex = 0; depIndex < rawDependencies.length; depIndex++) {
        final dependency = _trimmedString(rawDependencies[depIndex]);
        if (dependency == null) {
          errors.add('story_specs.items[$index].dependencies[$depIndex] must be a non-empty string.');
          continue;
        }
        dependencies.add(dependency);
      }
      normalizedItem['dependencies'] = dependencies;
    }

    normalizedItems.add(normalizedItem);
  }

  if (errors.isNotEmpty) {
    return (
      storySpecs: null,
      validationFailure: StepValidationFailure(
        reason: 'Plan skill produced invalid `story_specs`: ${errors.join(' ')}',
      ),
    );
  }

  return (storySpecs: {...storySpecs, 'items': normalizedItems}, validationFailure: null);
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

Map<String, dynamic>? _asStringKeyedMap(Object? value) {
  return switch (value) {
    final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
    final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
    _ => null,
  };
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
