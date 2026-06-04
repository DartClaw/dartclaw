import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_safety_policy.dart';
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

  final completedStoryIds = _readCompletedStoryIds(outputs['plan'], activeWorkspaceRoot: activeWorkspaceRoot);
  final contract = validateStorySpecsContract(outputs['story_specs'], completedStoryIds: completedStoryIds);
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

/// Reads the IDs of already-completed (`done`/`skipped`) plan stories so
/// dependency validation can tell a dependency on a completed prerequisite
/// (prune — already satisfied) apart from one on a typo or a non-completed
/// story the discovery step dropped (keep — must be rejected as unknown).
///
/// Returns null — leaving validation strict — when the plan path is missing,
/// not a `.json` file, outside the workspace root, absent on disk, unparseable,
/// or carries no completed stories.
Set<String>? _readCompletedStoryIds(Object? rawPlan, {required String? activeWorkspaceRoot}) {
  if (rawPlan is! String) return null;
  final rawPath = rawPlan.trim();
  if (rawPath.isEmpty || p.extension(rawPath).toLowerCase() != '.json') return null;
  if (activeWorkspaceRoot == null || activeWorkspaceRoot.isEmpty) return null;

  final String planPath;
  try {
    planPath = safeProjectRelativePath(rawPath, activeWorkspaceRoot, fieldName: 'plan', rejectRoot: true);
    validateArgumentSafePath(planPath, fieldName: 'plan', rawPath: rawPath);
  } on FormatException {
    return null;
  }

  final file = p.isAbsolute(planPath) ? File(planPath) : File(p.join(activeWorkspaceRoot, planPath));
  if (!file.existsSync() || !fileStaysInsideRoot(file, activeWorkspaceRoot)) return null;

  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final stories = decoded['stories'];
    if (stories is! List) return null;
    final ids = <String>{};
    for (final story in stories) {
      if (story is! Map) continue;
      final id = story['id'];
      if (id is! String || id.trim().isEmpty) continue;
      final status = story['status'];
      if (status == 'done' || status == 'skipped') ids.add(id.trim());
    }
    return ids.isEmpty ? null : ids;
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
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
