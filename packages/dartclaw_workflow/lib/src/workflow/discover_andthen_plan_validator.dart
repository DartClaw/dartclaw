import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_safety_policy.dart';
import 'step_output_validation_helpers.dart';
import 'workflow_runner_types.dart';

const _openStoryStatuses = <String>{'pending', 'spec-ready', 'in-progress', 'blocked'};

DiscoverAndthenPlanValidation validateDiscoverAndthenPlanOutputs(
  Map<String, dynamic> outputs, {
  required String? activeWorkspaceRoot,
}) {
  final rawPrd = stringValue(outputs['prd']).trim();
  if (rawPrd.isEmpty) {
    return (
      outputs: outputs,
      validationFailure: const StepValidationFailure(
        reason: 'Discover plan state must emit a non-empty existing PRD path.',
      ),
    );
  }

  final prdPath = _safePrdPath(rawPrd, activeWorkspaceRoot);
  final prdFailure = prdPath.validationFailure;
  if (prdFailure != null) return (outputs: outputs, validationFailure: prdFailure);

  final fileFailure = _validatePrdFile(prdPath.path!, activeWorkspaceRoot);
  if (fileFailure != null) return (outputs: outputs, validationFailure: fileFailure);
  return (
    outputs: _normalizeUnprovenEmptyStoryCatalog({...outputs, 'prd': prdPath.path}, activeWorkspaceRoot),
    validationFailure: null,
  );
}

({String? path, StepValidationFailure? validationFailure}) _safePrdPath(String rawPath, String? activeWorkspaceRoot) {
  try {
    return (
      path: safeWorkspaceRelativePath(
        rawPath,
        activeWorkspaceRoot: activeWorkspaceRoot,
        fieldName: 'prd',
        basenameMatcher: isPrdMarkdownPath,
        typeDescription: 'a PRD markdown path',
      ),
      validationFailure: null,
    );
  } on FormatException catch (e) {
    return (path: null, validationFailure: StepValidationFailure(reason: e.message));
  }
}

StepValidationFailure? _validatePrdFile(String path, String? activeWorkspaceRoot) {
  final root = activeWorkspaceRoot?.trim();
  if (root == null || root.isEmpty) return null;
  final file = File(p.join(root, path));
  if (!file.existsSync()) {
    return StepValidationFailure(
      reason: 'Discover plan state referenced a missing PRD file: $path.',
      missingArtifacts: [path],
    );
  }
  if (!fileStaysInsideRoot(file, root)) {
    return StepValidationFailure(reason: 'Discover plan state PRD resolves outside project root: $path.');
  }
  return null;
}

Map<String, dynamic> _normalizeUnprovenEmptyStoryCatalog(Map<String, dynamic> outputs, String? activeWorkspaceRoot) {
  final rawPlan = stringValue(outputs['plan']).trim();
  if (rawPlan.isEmpty || !_hasEmptyStoryCatalog(outputs['story_specs'])) return outputs;

  final safePlan = _safePlanPath(rawPlan, activeWorkspaceRoot);
  if (safePlan == null) return {...outputs, 'plan': ''};
  if (p.extension(safePlan).toLowerCase() != '.json') return {...outputs, 'plan': ''};

  final root = activeWorkspaceRoot?.trim();
  if (root == null || root.isEmpty) return {...outputs, 'plan': ''};
  final planFile = File(p.join(root, safePlan));
  if (!planFile.existsSync() || !fileStaysInsideRoot(planFile, root)) return {...outputs, 'plan': ''};
  if (!_jsonPlanHasNoExecutableStories(planFile)) return {...outputs, 'plan': ''};

  return {...outputs, 'plan': safePlan};
}

bool _hasEmptyStoryCatalog(Object? rawStorySpecs) {
  final storySpecs = asStringKeyedMap(rawStorySpecs);
  if (storySpecs == null) return false;
  final items = storySpecs['items'];
  return items is List && items.isEmpty;
}

String? _safePlanPath(String rawPlan, String? activeWorkspaceRoot) {
  try {
    final path = safeProjectRelativePath(rawPlan, activeWorkspaceRoot, fieldName: 'plan', rejectRoot: true);
    validateArgumentSafePath(path, fieldName: 'plan', rawPath: rawPlan);
    return path;
  } on FormatException {
    return null;
  }
}

bool _jsonPlanHasNoExecutableStories(File planFile) {
  try {
    final decoded = jsonDecode(planFile.readAsStringSync());
    if (decoded is! Map<String, dynamic>) return false;
    final stories = decoded['stories'];
    if (stories is! List) return false;
    for (final story in stories) {
      final storyMap = asStringKeyedMap(story);
      if (storyMap == null) return false;
      final fis = trimmedString(storyMap['fis']);
      if (fis == null) continue;
      final rawStatus = storyMap['status'];
      final status = rawStatus is String ? rawStatus : 'pending';
      if (_openStoryStatuses.contains(status) || !_isKnownTerminalStatus(status)) return false;
    }
    return true;
  } on FormatException {
    return false;
  } on FileSystemException {
    return false;
  }
}

bool _isKnownTerminalStatus(String status) => status == 'done' || status == 'skipped';
