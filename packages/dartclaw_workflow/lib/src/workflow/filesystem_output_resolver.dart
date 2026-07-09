import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'missing_artifact_failure.dart';
import 'output_resolver.dart';
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
/// Returns the safe relative path if valid and on-disk, null otherwise. The
/// trust boundary for an explicit claim is containment + on-disk existence
/// (argument-safety is enforced separately downstream, per ADR-041) — *not* the
/// output's [FileSystemOutput.pathPattern]. That glob is a discovery selector
/// for picking an unnamed artifact out of the worktree diff
/// ([safeChangedFileSystemMatches]); applying it here would reject a path the
/// skill named explicitly (e.g. a `report-draft.md` claimed for a `report`
/// output whose glob is `**/*report*.md`) even though it exists and is contained.
String? safeRelativeExistingFileClaim(
  String value, {
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
  List<String> values, {
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

/// Returns paths from [values] that match the worktree diff, validated for
/// containment. [values] is already glob-filtered by the caller (the
/// `pathPattern` selects which diff entries are candidates); this stage only
/// applies the containment + existence trust boundary.
List<String> safeChangedFileSystemMatches(
  Iterable<String> values, {
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

/// Resolves the filesystem output for a step, applying git-diff filtering and
/// claimed-path validation.
///
/// Review-artifact path outputs never reach this resolver — they are captured
/// deterministically from the host-owned step artifacts dir
/// (`resolveReviewArtifactFromStepDir` in `review_artifact_policy.dart`).
///
/// When [git] is null or [worktreePath] is empty, falls back to existence-only
/// validation (no diff filtering). Otherwise performs a `git diff --name-only`
/// and intersects with the claimed paths.
Future<Object?> resolveFileSystemOutput(
  FileSystemOutput resolver, {
  required String outputKey,
  required Task task,
  required List<String> claimedPaths,
  required List<String> changedMatches,
  required Map<String, String> existingClaims,
  required WorkflowGitPort? git,
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
      if (resolver.listMode || changedMatches.length == 1) {
        _log.warning(
          'Ignoring stale claimed path(s) for "$outputKey" on task ${task.id}: '
          '$missingClaims; using changed file(s): $changedMatches',
        );
        return resolver.listMode ? changedMatches : changedMatches.single;
      }
      throw StateError(
        'Multiple filesystem artifacts matched "$outputKey" in $worktreePath '
        'after stale claims $missingClaims: $changedMatches',
      );
    }
    throw MissingArtifactFailure(
      claimedPaths: claimedPaths,
      missingPaths: missingClaims,
      worktreePath: worktreePath,
      fieldName: outputKey,
      reason: 'path claimed but not present in worktree diff',
    );
  }

  if (claimedPaths.isNotEmpty) {
    final matchingClaims = changedFileSystemOutputClaims(claimedPaths, existingClaims, changedMatches);
    if (matchingClaims.isNotEmpty && !resolver.listMode) {
      if (matchingClaims.length == 1) return matchingClaims.single;
      throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $matchingClaims');
    }
    final safeClaims = safeFileSystemOutputClaims(claimedPaths, existingClaims, changedMatches);
    if (resolver.listMode) return safeClaims;
    if (safeClaims.length == 1) return safeClaims.single;
    throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $safeClaims');
  }
  if (resolver.listMode) return changedMatches;
  if (changedMatches.isEmpty) return '';
  if (changedMatches.length == 1) return changedMatches.single;
  final preferredMatch = _preferredSingularMatch(resolver.preferPatterns, changedMatches);
  if (preferredMatch != null) return preferredMatch;
  throw StateError('Multiple filesystem artifacts matched "$outputKey" in $worktreePath: $changedMatches');
}

/// Picks a single winner from [matches] using the output's declared
/// [FileSystemOutput.preferPatterns]: the first bare basename (compared
/// case-insensitively) with exactly one matching candidate wins. Returns null
/// when no preference resolves a unique match, leaving the ambiguity to surface
/// as a failure.
String? _preferredSingularMatch(List<String> preferPatterns, List<String> matches) {
  for (final basename in preferPatterns) {
    final lowered = basename.toLowerCase();
    final hits = matches.where((match) => p.basename(match).toLowerCase() == lowered).toList()..sort();
    if (hits.length == 1) return hits.single;
  }
  return null;
}
