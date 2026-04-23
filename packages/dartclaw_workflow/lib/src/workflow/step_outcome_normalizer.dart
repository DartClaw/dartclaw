import 'dart:io';

import 'package:path/path.dart' as p;

import 'workflow_runner_types.dart';

/// Context needed by pure step-output normalization.
final class StepOutputNormalizationContext {
  final String planDir;
  final String? projectRoot;

  const StepOutputNormalizationContext({this.planDir = '', this.projectRoot});
}

/// Normalizes output envelopes and returns a typed handoff.
StepHandoff normalizeOutputs(Map<String, dynamic> envelope, StepOutputNormalizationContext context) {
  final normalized = validateStorySpecOutputs(
    envelope,
    planDir: context.planDir,
    projectRoot: context.projectRoot,
  );
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

  final rawStorySpecs = outputs['story_specs'];
  if (rawStorySpecs is List) {
    return _validateStorySpecPathList(outputs, rawStorySpecs, planDir: planDir, projectRoot: projectRoot);
  }
  if (rawStorySpecs is! Map<String, dynamic>) {
    return (outputs: outputs, validationFailure: null);
  }
  final rawItems = rawStorySpecs['items'];
  if (rawItems is! List) {
    return (outputs: outputs, validationFailure: null);
  }

  final missingSpecPaths = <String>[];
  final normalizedItems = <Map<String, dynamic>>[];

  for (final item in rawItems) {
    final itemMap = switch (item) {
      final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
      final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
      _ => <String, dynamic>{},
    };
    final rawSpecPath = (itemMap['spec_path'] as String?)?.trim();
    if (rawSpecPath != null && rawSpecPath.isNotEmpty) {
      final normalizedSpecPath = resolveStorySpecPathAgainstPlanDir(path: rawSpecPath, planDir: planDir);
      itemMap['spec_path'] = normalizedSpecPath;
      if (!_storySpecPathExists(normalizedSpecPath, projectRoot: projectRoot)) {
        missingSpecPaths.add(normalizedSpecPath);
      }
    }
    normalizedItems.add(itemMap);
  }

  final result = <String, dynamic>{
    ...outputs,
    'story_specs': {...rawStorySpecs, 'items': normalizedItems},
  };
  return (outputs: result, validationFailure: _missingStorySpecFailure(missingSpecPaths));
}

/// Resolves a `story_specs.spec_path` value against [planDir] exactly once.
String resolveStorySpecPathAgainstPlanDir({required String path, required String planDir}) {
  if (path.isEmpty) return path;
  if (p.isAbsolute(path)) return p.normalize(path);
  if (planDir.isEmpty || planDir == '.') return p.normalize(path);
  final normalizedSpec = p.normalize(path);
  if (_isAlreadyPlanRooted(normalizedSpec, planDir)) {
    return normalizedSpec;
  }
  return p.normalize(p.join(planDir, path));
}

StorySpecOutputValidation _validateStorySpecPathList(
  Map<String, dynamic> outputs,
  List<dynamic> rawPaths, {
  required String planDir,
  required String? projectRoot,
}) {
  final normalizedPaths = <String>[];
  final missingSpecPaths = <String>[];
  for (final rawPath in rawPaths) {
    final specPath = rawPath.toString().trim();
    if (specPath.isEmpty) continue;
    final normalizedPath = resolveStorySpecPathAgainstPlanDir(path: specPath, planDir: planDir);
    normalizedPaths.add(normalizedPath);
    if (!_storySpecPathExists(normalizedPath, projectRoot: projectRoot)) {
      missingSpecPaths.add(normalizedPath);
    }
  }
  return (
    outputs: {...outputs, 'story_specs': normalizedPaths},
    validationFailure: _missingStorySpecFailure(missingSpecPaths),
  );
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

bool _isAlreadyPlanRooted(String specPath, String planDir) {
  final normalizedPlanDir = p.normalize(planDir);
  final planDirPrefix = normalizedPlanDir.endsWith(p.separator)
      ? normalizedPlanDir
      : '$normalizedPlanDir${p.separator}';
  return specPath == normalizedPlanDir || specPath.startsWith(planDirPrefix);
}
