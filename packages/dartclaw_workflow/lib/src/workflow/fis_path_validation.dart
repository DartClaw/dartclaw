import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_safety_policy.dart';
import 'workflow_runner_types.dart';

({String? path, StepValidationFailure? validationFailure}) existingFisFeaturePath(
  String feature,
  String? activeWorkspaceRoot,
) {
  final root = activeWorkspaceRoot?.trim();
  if (root == null || root.isEmpty || !isWholeFisCandidate(feature)) {
    return (path: null, validationFailure: null);
  }
  final featurePath = safeFisPath(feature, root, fieldName: 'FEATURE');
  if (featurePath.validationFailure != null) return (path: null, validationFailure: featurePath.validationFailure);
  final path = featurePath.path;
  if (path == null) return (path: null, validationFailure: null);
  final fileFailure = validateExistingFisFile(path, root, featureFieldName: 'FEATURE');
  return fileFailure == null ? (path: path, validationFailure: null) : (path: null, validationFailure: fileFailure);
}

({String? path, StepValidationFailure? validationFailure}) safeFisPath(
  String rawPath,
  String? activeWorkspaceRoot, {
  required String fieldName,
}) {
  try {
    return (
      path: safeWorkspaceRelativePath(
        rawPath,
        activeWorkspaceRoot: activeWorkspaceRoot,
        fieldName: fieldName,
        basenameMatcher: isFisMarkdownPath,
        typeDescription: 'an sNN-style markdown FIS path',
      ),
      validationFailure: null,
    );
  } on FormatException catch (e) {
    return (path: null, validationFailure: StepValidationFailure(reason: e.message));
  }
}

StepValidationFailure? validateExistingFisFile(
  String path,
  String? activeWorkspaceRoot, {
  required String featureFieldName,
}) {
  final root = activeWorkspaceRoot?.trim();
  if (root == null || root.isEmpty) return null;
  final file = File(p.join(root, path));
  if (!file.existsSync()) {
    return StepValidationFailure(
      reason: 'Detect spec input referenced a missing FIS file: $path.',
      missingArtifacts: [path],
    );
  }
  if (!fileStaysInsideRoot(file, root)) {
    return StepValidationFailure(reason: 'Detect spec input $featureFieldName resolves outside project root: $path.');
  }
  if (!containsFisMarker(file)) {
    return StepValidationFailure(
      reason: 'Detect spec input referenced a markdown file without FIS marker headers: $path.',
    );
  }
  return null;
}

bool containsFisMarker(File file) {
  final content = file.readAsStringSync();
  return RegExp(
    r'^## (Scope|Acceptance Criteria|Touched Files|Implementation Plan)\s*$',
    multiLine: true,
  ).hasMatch(content);
}

bool isWholeFisCandidate(String path) {
  final value = path.trim();
  if (value.contains(RegExp(r'[\x00-\x20\x7f]'))) return false;
  return isFisMarkdownPath(value) && (p.dirname(value) != '.' || value.contains('/'));
}
