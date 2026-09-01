import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'missing_artifact_failure.dart';
import 'output_resolver.dart';
import 'review_artifact_policy.dart';
import 'workflow_definition.dart' show WorkflowStep;
import 'workflow_run_paths.dart';

final _log = Logger('ContextExtractor');

/// A containment root a `format: path` claim may resolve under.
///
/// [absoluteValues] marks an engine-owned root (the step artifacts dir, the
/// run's runtime-artifacts dir). A value resolved under such a root reaches
/// context as an absolute path: downstream steps interpolate *relative* path
/// values as workspace-relative skill arguments, so a root-relative form would
/// point them at the wrong file. Worktree and project-data roots stay
/// root-relative.
typedef FileSystemOutputRoot = ({String path, bool absoluteValues});

/// The host-owned step artifacts dir as a containment root, or nothing when the
/// task carries no workflow run.
List<FileSystemOutputRoot> stepArtifactsFileSystemOutputRoots(String stepArtifactsDir) =>
    stepArtifactsDir.isEmpty ? const [] : [(path: stepArtifactsDir, absoluteValues: true)];

/// Collects worktree roots from task metadata.
List<FileSystemOutputRoot> worktreeFileSystemOutputRoots(Map<String, dynamic>? worktreeJson) {
  final worktreePath = (worktreeJson?['path'] as String?)?.trim();
  return worktreePath == null || worktreePath.isEmpty
      ? <FileSystemOutputRoot>[]
      : <FileSystemOutputRoot>[(path: worktreePath, absoluteValues: false)];
}

/// Collects the containment roots that are valid for a task's output claims,
/// in resolution order.
///
/// The host-owned step artifacts dir comes first (empty [stepArtifactsDir] =
/// the task has no workflow run), so a relative claim that collides with a
/// worktree file resolves to the copy the host controls (TD-093) without any
/// name-keyed special case. Worktree, runtime-artifacts and project-data roots
/// follow.
List<FileSystemOutputRoot> fileSystemOutputRoots({
  required String stepArtifactsDir,
  required Map<String, dynamic>? worktreeJson,
  required String? workflowRunId,
  required String? projectId,
  required String dataDir,
}) {
  final roots = <FileSystemOutputRoot>[
    ...stepArtifactsFileSystemOutputRoots(stepArtifactsDir),
    ...worktreeFileSystemOutputRoots(worktreeJson),
  ];
  final runId = workflowRunId?.trim();
  if (runId != null && runId.isNotEmpty) {
    roots.add((path: workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId), absoluteValues: true));
  }
  final pid = projectId?.trim();
  if (pid != null && pid.isNotEmpty && pid != '_local') {
    roots.add((path: p.join(dataDir, 'projects', pid), absoluteValues: false));
  }
  return roots;
}

/// Validates one agent-claimed path against a set of known roots.
///
/// Returns the resolved value if the claim is contained and on-disk, null
/// otherwise — root-relative for a workspace root, absolute for an
/// engine-owned one ([FileSystemOutputRoot.absoluteValues]).
///
/// The trust boundary for an explicit claim is containment + on-disk existence
/// (argument-safety is enforced separately downstream, per ADR-041) — *not* the
/// output's [FileSystemOutput.pathPattern]. That glob is a discovery selector
/// for picking an unclaimed artifact out of the step artifacts dir
/// ([captureStepArtifact]); applying it here would reject a path the skill
/// named explicitly (e.g. a `report-draft.md` claimed for a `report` output
/// whose glob is `**/*report*.md`) even though it exists and is contained.
///
/// The claim is taken literally: no prefix-stripped alternative is tried, so a
/// step that names `<worktreeName>/report.md` gets that file or a failure,
/// never a same-named file one directory up.
String? safeRelativeExistingFileClaim(String value, {required List<FileSystemOutputRoot> roots, String? taskId}) {
  for (final root in roots) {
    try {
      final normalizedRoot = p.normalize(root.path);
      if (!Directory(normalizedRoot).existsSync()) continue;
      final claim = p.normalize(value);
      final candidate = p.normalize(p.isAbsolute(claim) ? claim : p.join(normalizedRoot, claim));
      if (!p.isWithin(normalizedRoot, candidate) || !File(candidate).existsSync()) continue;
      final resolvedRoot = p.normalize(Directory(normalizedRoot).resolveSymbolicLinksSync());
      final resolvedCandidate = p.normalize(File(candidate).resolveSymbolicLinksSync());
      if (!p.isWithin(resolvedRoot, resolvedCandidate)) continue;
      return root.absoluteValues ? candidate : p.normalize(p.relative(candidate, from: normalizedRoot));
    } catch (error, st) {
      _log.fine('Path-existence probe failed for "$value" on task $taskId: $error\n$st');
    }
  }
  return null;
}

/// Resolves all valid existing claims from a set of agent-supplied path strings.
Map<String, String> existingSafeFileClaims(
  List<String> values, {
  required List<FileSystemOutputRoot> roots,
  String? taskId,
}) {
  final claims = <String, String>{};
  for (final value in values) {
    final safeClaim = safeRelativeExistingFileClaim(value, roots: roots, taskId: taskId);
    if (safeClaim != null) claims[value] = safeClaim;
  }
  return claims;
}

/// Resolves the filesystem output for a step under one rule for every
/// `format: path` output.
///
/// An existing, symlink-contained claim wins. With no usable claim the value is
/// captured from the host-owned step artifacts dir, selected by the output's own
/// declared [FileSystemOutput.pathPattern] (see [captureStepArtifact]). When
/// neither yields a value, a step that reported a clean review gets the
/// diagnostic stub, a step that owes an artifact fails, and anything else
/// resolves empty.
///
/// No output is recognized as a review to pick a resolution path, and no git
/// operation runs: the worktree diff is not consulted.
Object? resolveFileSystemOutput(
  FileSystemOutput resolver, {
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required List<String> claimedPaths,
  required Map<String, String> existingClaims,
  required String stepArtifactsDir,
  required Map<String, dynamic> claimPayload,
  bool claimsExplicitlyEmpty = false,
}) {
  // An explicit "no path" claim from the agent (e.g. `plan: ""` per the
  // discover-plan-state contract) must short-circuit before the step-dir
  // capture can substitute an unrelated artifact.
  if (claimsExplicitlyEmpty && claimedPaths.isEmpty) {
    return resolver.listMode ? const <String>[] : '';
  }

  if (existingClaims.isNotEmpty) {
    final missingPaths = claimedPaths.where((path) => !existingClaims.containsKey(path)).toList();
    if (missingPaths.isNotEmpty) {
      throw MissingArtifactFailure(
        claimedPaths: claimedPaths,
        missingPaths: missingPaths,
        worktreePath: _worktreePath(task),
        fieldName: outputKey,
        reason: _unresolvedClaimReason,
      );
    }
    final safeClaims = existingClaims.values.toSet().toList()..sort();
    if (resolver.listMode) return safeClaims;
    if (safeClaims.length == 1) return safeClaims.single;
    throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $safeClaims');
  }

  final captured = stepArtifactsDir.isEmpty
      ? null
      : captureStepArtifact(stepArtifactsDir, resolver, outputKey: outputKey, taskId: task.id);
  if (captured != null) return resolver.listMode ? captured : captured.single;

  if (reportedCleanReview(step, claimPayload)) {
    final stub = stepArtifactsDir.isEmpty
        ? null
        : materializeUnclaimedCleanReviewArtifact(
            outputKey: outputKey,
            step: step,
            task: task,
            claimPayload: claimPayload,
            stepArtifactsDir: stepArtifactsDir,
          );
    if (stub != null) return resolver.listMode ? <String>[stub] : stub;
    _log.warning(
      'No artifact found in the step artifacts dir for clean review "$outputKey" on task ${task.id}; '
      'returning empty instead of matching unrelated files.',
    );
    return resolver.listMode ? const <String>[] : '';
  }

  // A step that named a path, or that reported findings it owes a report for,
  // fails visibly rather than resolving empty.
  if (claimedPaths.isNotEmpty) {
    throw MissingArtifactFailure(
      claimedPaths: claimedPaths,
      missingPaths: claimedPaths,
      worktreePath: _worktreePath(task),
      fieldName: outputKey,
      reason: _unresolvedClaimReason,
    );
  }
  if (reportedFindingsCount(step, claimPayload) != null) {
    throw MissingArtifactFailure(
      claimedPaths: const [],
      missingPaths: [if (stepArtifactsDir.isNotEmpty) stepArtifactsDir],
      worktreePath: _worktreePath(task),
      fieldName: outputKey,
      reason: 'no artifact found in the step artifacts dir',
    );
  }
  return resolver.listMode ? const <String>[] : '';
}

/// Stable reason for a claim that is not an existing, contained file under any
/// allowed root — and that the step artifacts dir could not satisfy either.
const _unresolvedClaimReason = 'path claimed but not found under an allowed root';

String _worktreePath(Task task) => (task.worktreeJson?['path'] as String?)?.trim() ?? '';
