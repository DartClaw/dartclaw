import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'workflow_definition.dart' show WorkflowStep;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'missing_artifact_failure.dart';
import 'output_resolver.dart';
import 'review_artifact_policy.dart' as rap;
import 'workflow_git_port.dart';
import 'workflow_run_paths.dart';

final _log = Logger('ContextExtractor');

/// Collects worktree roots from task metadata.
List<String> worktreeFileSystemOutputRoots(Map<String, dynamic>? worktreeJson) {
  final worktreePath = (worktreeJson?['path'] as String?)?.trim();
  return worktreePath == null || worktreePath.isEmpty ? <String>[] : <String>[worktreePath];
}

/// Collects all filesystem roots that are valid for a task's output claims.
///
/// Includes worktree path, runtime-artifacts dir (if task has a workflow run),
/// and project-data dir (if task has a non-local project).
List<String> fileSystemOutputRoots({
  required Map<String, dynamic>? worktreeJson,
  required String? workflowRunId,
  required String? projectId,
  required String dataDir,
}) {
  final roots = worktreeFileSystemOutputRoots(worktreeJson);
  final runId = workflowRunId?.trim();
  if (runId != null && runId.isNotEmpty) {
    roots.add(workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId));
  }
  final pid = projectId?.trim();
  if (pid != null && pid.isNotEmpty && pid != '_local') {
    roots.add(p.join(dataDir, 'projects', pid));
  }
  return roots;
}

bool isRuntimeArtifactsRoot(String root, {required String? workflowRunId, required String dataDir}) {
  final runId = workflowRunId?.trim();
  if (runId == null || runId.isEmpty) return false;
  return p.normalize(root) == p.normalize(workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId));
}

/// Validates that a runtime-artifacts claim is fully within [runtimeArtifactsDir].
///
/// Returns the claim relative to [runtimeArtifactsDir], or null when containment
/// cannot be established.
String? runtimeArtifactsRelativeClaim(String claim, String runtimeArtifactsDir) {
  final normalizedClaim = p.normalize(claim);
  if (!p.isAbsolute(normalizedClaim)) return null;

  final roots = <String>{p.normalize(runtimeArtifactsDir)};
  try {
    if (Directory(runtimeArtifactsDir).existsSync()) {
      roots.add(p.normalize(Directory(runtimeArtifactsDir).resolveSymbolicLinksSync()));
    }
  } catch (_) {
    // Unresolved string root still protects the common non-symlink case.
  }

  for (final root in roots) {
    if (p.isWithin(root, normalizedClaim)) {
      final relative = p.normalize(p.relative(normalizedClaim, from: root));
      if (!runtimeArtifactsClaimStaysInside(runtimeArtifactsDir, normalizedClaim)) return null;
      return relative;
    }
  }
  return null;
}

/// Symlink-aware containment check for runtime-artifacts claims.
bool runtimeArtifactsClaimStaysInside(String runtimeArtifactsDir, String claim) {
  try {
    final resolvedRoot = Directory(runtimeArtifactsDir).resolveSymbolicLinksSync();
    final resolvedClaim = resolveExistingPathOrParent(claim);
    if (resolvedClaim == null) return false;
    return resolvedClaim == resolvedRoot || p.isWithin(resolvedRoot, resolvedClaim);
  } on FileSystemException {
    // runtimeArtifactsDir doesn't exist yet (first claim in a brand-new run).
    // String containment suffices when no symlinks can exist inside a non-existent dir.
    return p.isWithin(p.normalize(runtimeArtifactsDir), claim);
  }
}

/// Resolves [path] if it exists, or its parent if [path] does not yet exist.
String? resolveExistingPathOrParent(String path) {
  if (File(path).existsSync()) return File(path).resolveSymbolicLinksSync();
  if (Directory(path).existsSync()) return Directory(path).resolveSymbolicLinksSync();
  final parent = Directory(p.dirname(path));
  if (!parent.existsSync()) return null;
  return p.normalize(p.join(parent.resolveSymbolicLinksSync(), p.basename(path)));
}

/// Returns candidate path strings to try when resolving an agent claim.
///
/// Order is load-bearing: the un-stripped form is tried first so that a
/// worktree containing both `<root>/<projectId>/foo.md` and `<root>/foo.md`
/// resolves to the agent's literal claim rather than the stripped fallback.
List<String> relativeClaimCandidates(String value, String root, {String? projectId}) {
  final normalized = p.normalize(value);
  if (p.isAbsolute(normalized)) return [normalized];
  final candidates = <String>[normalized];
  final parts = p.split(normalized);
  final removablePrefixes = {p.basename(root), if (projectId?.trim().isNotEmpty ?? false) projectId!.trim()};
  if (parts.length > 1 && removablePrefixes.contains(parts.first)) {
    candidates.add(p.joinAll(parts.skip(1)));
  }
  return candidates;
}

/// Validates one agent-claimed path against a set of known roots.
///
/// Returns the safe relative path if valid and on-disk, null otherwise.
String? safeRelativeExistingFileClaim(
  String value,
  FileSystemOutput resolver, {
  bool preserveRuntimeArtifactsRoot = false,
  required List<String> roots,
  required String? taskId,
  required String? projectId,
  required String? workflowRunId,
  required String dataDir,
}) {
  for (final root in roots) {
    try {
      final normalizedRoot = p.normalize(root);
      if (!Directory(normalizedRoot).existsSync()) continue;
      final candidates = relativeClaimCandidates(value, normalizedRoot, projectId: projectId);
      for (var i = 0; i < candidates.length; i++) {
        final claim = candidates[i];
        final candidate = p.normalize(p.isAbsolute(claim) ? claim : p.join(normalizedRoot, claim));
        if (!p.isWithin(normalizedRoot, candidate) || !File(candidate).existsSync()) continue;
        final resolvedRoot = p.normalize(Directory(normalizedRoot).resolveSymbolicLinksSync());
        final resolvedCandidate = p.normalize(File(candidate).resolveSymbolicLinksSync());
        if (!p.isWithin(resolvedRoot, resolvedCandidate)) continue;
        final relative = p.normalize(p.relative(candidate, from: normalizedRoot));
        if (!resolver.matches(relative)) continue;
        if (preserveRuntimeArtifactsRoot &&
            isRuntimeArtifactsRoot(normalizedRoot, workflowRunId: workflowRunId, dataDir: dataDir)) {
          return candidate;
        }
        if (i > 0) {
          _log.fine(
            'Path-existence probe stripped prefix from "$value" → "$relative" under "$normalizedRoot" for task $taskId',
          );
        }
        return relative;
      }
    } catch (error, st) {
      _log.fine('Path-existence probe failed for "$value" on task $taskId: $error\n$st');
    }
  }
  return null;
}

/// Resolves all valid existing claims from a set of agent-supplied path strings.
Map<String, String> existingSafeFileClaims(
  List<String> values,
  FileSystemOutput resolver, {
  required bool preserveRuntimeArtifactsRoot,
  required List<String> roots,
  required String? taskId,
  required String? projectId,
  required String? workflowRunId,
  required String dataDir,
}) {
  final claims = <String, String>{};
  for (final value in values) {
    final safeClaim = safeRelativeExistingFileClaim(
      value,
      resolver,
      preserveRuntimeArtifactsRoot: preserveRuntimeArtifactsRoot,
      roots: roots,
      taskId: taskId,
      projectId: projectId,
      workflowRunId: workflowRunId,
      dataDir: dataDir,
    );
    if (safeClaim != null) claims[value] = safeClaim;
  }
  return claims;
}

/// Returns paths from [values] that match the worktree diff, validated for containment.
List<String> safeChangedFileSystemMatches(
  Iterable<String> values,
  FileSystemOutput resolver, {
  required List<String> worktreeRoots,
  required String? taskId,
  required String? projectId,
  required String? workflowRunId,
  required String dataDir,
}) {
  return values
      .map(
        (value) => safeRelativeExistingFileClaim(
          value,
          resolver,
          roots: worktreeRoots,
          taskId: taskId,
          projectId: projectId,
          workflowRunId: workflowRunId,
          dataDir: dataDir,
        ),
      )
      .whereType<String>()
      .toSet()
      .toList()
    ..sort();
}

/// Intersects explicitly claimed paths with changed-file matches.
List<String> changedFileSystemOutputClaims(
  List<String> claimedPaths,
  Map<String, String> existingClaims,
  List<String> changedMatches,
) {
  return claimedPaths
      .map((path) => existingClaims[path] ?? p.normalize(path))
      .where(changedMatches.contains)
      .toSet()
      .toList()
    ..sort();
}

/// Union of explicitly claimed paths that intersect with the changed set, plus
/// all other existing claims.
List<String> safeFileSystemOutputClaims(
  List<String> claimedPaths,
  Map<String, String> existingClaims,
  List<String> changedMatches,
) {
  return claimedPaths
      .map((path) => existingClaims[path] ?? p.normalize(path))
      .where(changedMatches.contains)
      .followedBy(existingClaims.values)
      .toSet()
      .toList()
    ..sort();
}

/// Filters [claims] to those that fall within the runtime-artifacts directory.
List<String> runtimeArtifactsOutputClaims(
  Iterable<String> claims, {
  required String? workflowRunId,
  required String dataDir,
}) {
  final runId = workflowRunId?.trim();
  if (runId == null || runId.isEmpty) return const <String>[];
  final runtimeArtifactsDir = workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId);
  return claims
      .map(p.normalize)
      .where((claim) => runtimeArtifactsRelativeClaim(claim, runtimeArtifactsDir) != null)
      .toSet()
      .toList()
    ..sort();
}

/// Resolves the filesystem output for a step, applying git-diff filtering,
/// claimed-path validation, and review-artifact policy.
///
/// When [git] is null or [worktreePath] is empty, falls back to existence-only
/// validation (no diff filtering). Otherwise performs a `git diff --name-only`
/// and intersects with the claimed paths.
Future<Object?> resolveFileSystemOutput(
  FileSystemOutput resolver, {
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required List<String> claimedPaths,
  required List<String> changedMatches,
  required Map<String, String> existingClaims,
  required bool preservesRuntimeArtifactsRoot,
  required Map<String, dynamic>? workflowContextPayload,
  required WorkflowGitPort? git,
  required String dataDir,
  bool claimsExplicitlyEmpty = false,
}) async {
  // An explicit "no path" claim from the agent (e.g. `plan: ""` per the
  // discover-plan-state contract) must short-circuit before changed-file
  // fallback can substitute an unrelated dirty file from the worktree.
  if (claimsExplicitlyEmpty && claimedPaths.isEmpty) {
    return resolver.listMode ? const <String>[] : '';
  }
  final worktreePath = (task.worktreeJson?['path'] as String?)?.trim() ?? '';

  if (git == null || worktreePath.isEmpty) {
    final missingPaths = claimedPaths.where((path) => !existingClaims.containsKey(path)).toList();
    if (missingPaths.isNotEmpty) {
      if (rap.allowsMissingCleanReviewArtifact(outputKey, step, resolver, workflowContextPayload)) {
        final fallback = rap.materializeMissingCleanReviewArtifact(
          outputKey: outputKey,
          step: step,
          task: task,
          resolver: resolver,
          missingClaims: missingPaths,
          workflowContextPayload: workflowContextPayload,
          dataDir: dataDir,
        );
        if (fallback != null) return resolver.listMode ? <String>[fallback] : fallback;
        _log.warning(
          'Ignoring missing clean review artifact claim(s) for "$outputKey" on task ${task.id}: $missingPaths',
        );
        return resolver.listMode ? const <String>[] : '';
      }
      throw MissingArtifactFailure(
        claimedPaths: claimedPaths,
        missingPaths: missingPaths,
        worktreePath: worktreePath,
        fieldName: outputKey,
        reason: 'path claimed but not present in worktree diff',
      );
    }
    final safeClaims = existingClaims.values.toList()..sort();
    if (resolver.listMode) return safeClaims;
    return safeClaims.isEmpty ? '' : safeClaims.single;
  }

  final missingClaims = claimedPaths
      .where(
        (path) =>
            !changedMatches.contains(existingClaims[path] ?? p.normalize(path)) && !existingClaims.containsKey(path),
      )
      .toList();
  if (missingClaims.isNotEmpty) {
    if (changedMatches.isNotEmpty) {
      _log.warning(
        'Ignoring stale claimed path(s) for "$outputKey" on task ${task.id}: '
        '$missingClaims; using changed file(s): $changedMatches',
      );
      if (resolver.listMode) return changedMatches;
      if (changedMatches.length == 1) return changedMatches.single;
      throw StateError(
        'Multiple filesystem artifacts matched "$outputKey" in $worktreePath '
        'after stale claims $missingClaims: $changedMatches',
      );
    }
    if (rap.allowsMissingCleanReviewArtifact(outputKey, step, resolver, workflowContextPayload)) {
      final fallback = rap.materializeMissingCleanReviewArtifact(
        outputKey: outputKey,
        step: step,
        task: task,
        resolver: resolver,
        missingClaims: missingClaims,
        workflowContextPayload: workflowContextPayload,
        dataDir: dataDir,
      );
      if (fallback != null) return resolver.listMode ? <String>[fallback] : fallback;
      _log.warning(
        'Ignoring missing clean review artifact claim(s) for "$outputKey" on task ${task.id}: $missingClaims',
      );
      return resolver.listMode ? const <String>[] : '';
    }
    throw MissingArtifactFailure(
      claimedPaths: claimedPaths,
      missingPaths: missingClaims,
      worktreePath: worktreePath,
      fieldName: outputKey,
      reason: 'path claimed but not present in worktree diff',
    );
  }

  final prefersChanged = rap.isReviewArtifactPathOutput(outputKey, step, resolver, workflowContextPayload);

  if (claimedPaths.isNotEmpty) {
    final matchingClaims = changedFileSystemOutputClaims(claimedPaths, existingClaims, changedMatches);
    final runtimeClaims = preservesRuntimeArtifactsRoot
        ? runtimeArtifactsOutputClaims(existingClaims.values, workflowRunId: task.workflowRunId, dataDir: dataDir)
        : const <String>[];
    if (runtimeClaims.isNotEmpty) {
      if (resolver.listMode) return runtimeClaims;
      if (runtimeClaims.length == 1) return runtimeClaims.single;
      throw StateError('Multiple runtime artifacts were explicitly claimed for "$outputKey": $runtimeClaims');
    }
    if (matchingClaims.isNotEmpty && (prefersChanged || !resolver.listMode)) {
      if (resolver.listMode) return matchingClaims;
      if (matchingClaims.length == 1) return matchingClaims.single;
      throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $matchingClaims');
    }
    if (prefersChanged && changedMatches.isNotEmpty) {
      if (resolver.listMode) return changedMatches;
      if (changedMatches.length == 1) return changedMatches.single;
      throw StateError('Multiple filesystem artifacts matched "$outputKey" in $worktreePath: $changedMatches');
    }
    final safeClaims = safeFileSystemOutputClaims(claimedPaths, existingClaims, changedMatches);
    if (resolver.listMode) return safeClaims;
    if (safeClaims.length == 1) return safeClaims.single;
    throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $safeClaims');
  }
  if (resolver.listMode) return changedMatches;
  if (changedMatches.isEmpty) return '';
  if (changedMatches.length == 1) return changedMatches.single;
  final preferredMatch = _preferredSingularMatch(outputKey, changedMatches);
  if (preferredMatch != null) return preferredMatch;
  throw StateError('Multiple filesystem artifacts matched "$outputKey" in $worktreePath: $changedMatches');
}

String? _preferredSingularMatch(String outputKey, List<String> matches) {
  if (outputKey == 'prd' || outputKey == 'prd_path') {
    final prdMatches = matches.where((match) => p.basename(match).toLowerCase() == 'prd.md').toList()..sort();
    if (prdMatches.length == 1) return prdMatches.single;
    return null;
  }
  if (outputKey == 'plan' || outputKey == 'plan_path') {
    for (final basename in const ['plan.json', 'plan.md']) {
      final planMatches = matches.where((match) => p.basename(match).toLowerCase() == basename).toList()..sort();
      if (planMatches.length == 1) return planMatches.single;
    }
  }
  return null;
}
