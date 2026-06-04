import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'workflow_definition.dart' show OutputFormat, WorkflowStep;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'filesystem_output_resolver.dart' show runtimeArtifactsRelativeClaim;
import 'output_resolver.dart';
import 'review_finding_derivations.dart' show firstIntegerForKeys;
import 'workflow_run_paths.dart';

final _log = Logger('ContextExtractor');

/// Returns true if the output key represents a review artifact path output.
///
/// A key qualifies when its [OutputConfig] declares `format: path` AND the
/// step either declares review-count keys, the payload already contains
/// review counts, or the resolver's pattern contains "review" or "architecture".
bool isReviewArtifactPathOutput(
  String outputKey,
  WorkflowStep step,
  FileSystemOutput resolver,
  Map<String, dynamic>? workflowContextPayload,
) {
  if (step.outputs?[outputKey]?.format != OutputFormat.path) return false;
  return declaresReviewCounts(step) ||
      payloadHasReviewCounts(step, workflowContextPayload) ||
      hasReviewArtifactPattern(resolver);
}

/// Returns true when the resolver's path pattern implies a review artifact.
bool hasReviewArtifactPattern(FileSystemOutput resolver) {
  final pattern = resolver.pathPattern.toLowerCase();
  return pattern.contains('review') || pattern.contains('architecture');
}

/// Returns true when the step's output keys include a findings-count key.
bool declaresReviewCounts(WorkflowStep step) {
  final outputKeys = step.outputKeys.toSet();
  return outputKeys.contains('${step.id}.findings_count') ||
      outputKeys.contains('${step.id}.gating_findings_count') ||
      outputKeys.contains('findings_count') ||
      outputKeys.contains('gating_findings_count');
}

/// Returns true when [workflowContextPayload] contains a findings-count value.
bool payloadHasReviewCounts(WorkflowStep step, Map<String, dynamic>? workflowContextPayload) {
  if (workflowContextPayload == null) return false;
  return firstIntegerForKeys(workflowContextPayload, findingsCountKeys(step)) != null ||
      firstIntegerForKeys(workflowContextPayload, gatingFindingsCountKeys(step)) != null;
}

/// Returns the context keys that carry a findings count for [step].
List<String> findingsCountKeys(WorkflowStep step) => ['${step.id}.findings_count', 'findings_count'];

/// Returns the context keys that carry a gating-findings count for [step].
List<String> gatingFindingsCountKeys(WorkflowStep step) => [
  '${step.id}.gating_findings_count',
  'gating_findings_count',
];

/// Returns true when a missing clean review artifact is permissible.
///
/// A missing review artifact is allowed when the step is a review-artifact
/// path output AND the payload reports zero findings.
bool allowsMissingCleanReviewArtifact(
  String outputKey,
  WorkflowStep step,
  FileSystemOutput resolver,
  Map<String, dynamic>? workflowContextPayload,
) {
  if (!isReviewArtifactPathOutput(outputKey, step, resolver, workflowContextPayload) ||
      workflowContextPayload == null) {
    return false;
  }
  final fc = firstIntegerForKeys(workflowContextPayload, findingsCountKeys(step));
  final gc = firstIntegerForKeys(workflowContextPayload, gatingFindingsCountKeys(step));
  if (fc == null) return false;
  return fc == 0 && (gc == null || gc == 0);
}

/// Writes a diagnostic stub file for a missing clean review artifact.
///
/// Returns the materialized path on success, null otherwise. The stub is only
/// written when the claim falls within the workflow runtime-artifacts directory.
String? materializeMissingCleanReviewArtifact({
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required FileSystemOutput resolver,
  required List<String> missingClaims,
  required Map<String, dynamic>? workflowContextPayload,
  required String dataDir,
}) {
  final runId = task.workflowRunId?.trim();
  if (runId == null || runId.isEmpty) return null;

  final runtimeArtifactsDir = workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId);
  for (final claim in missingClaims.map(p.normalize)) {
    final relative = runtimeArtifactsRelativeClaim(claim, runtimeArtifactsDir);
    if (relative == null) continue;
    if (!resolver.matches(relative)) continue;

    return _writeMissingCleanReviewArtifact(
      claim,
      outputKey: outputKey,
      step: step,
      task: task,
      workflowContextPayload: workflowContextPayload,
      reason: 'after the agent claimed a missing zero-finding report',
    );
  }
  return null;
}

/// Writes a diagnostic artifact when a clean review omits its report path.
String? materializeUnclaimedCleanReviewArtifact({
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required FileSystemOutput resolver,
  required Map<String, dynamic>? workflowContextPayload,
  required String dataDir,
}) {
  final runId = task.workflowRunId?.trim();
  if (runId == null || runId.isEmpty) return null;

  final runtimeArtifactsDir = workflowRuntimeArtifactsDir(dataDir: dataDir, runId: runId);
  final reviewsDir = p.join(runtimeArtifactsDir, 'reviews');
  try {
    Directory(reviewsDir).createSync(recursive: true);
  } on FileSystemException catch (error, st) {
    _log.warning('Failed to create clean review artifact directory for "$outputKey" on task ${task.id}', error, st);
    return null;
  }

  for (final relative in _unclaimedCleanReviewArtifactCandidates(outputKey, step, task)) {
    if (!resolver.matches(relative)) continue;
    final claim = p.join(runtimeArtifactsDir, relative);
    if (runtimeArtifactsRelativeClaim(claim, runtimeArtifactsDir) == null) continue;
    return _writeMissingCleanReviewArtifact(
      claim,
      outputKey: outputKey,
      step: step,
      task: task,
      workflowContextPayload: workflowContextPayload,
      reason: 'after the agent reported zero findings without a report path',
    );
  }
  return null;
}

List<String> _unclaimedCleanReviewArtifactCandidates(String outputKey, WorkflowStep step, Task task) {
  final output = _pathSlug(outputKey);
  final stepId = _pathSlug(step.id);
  final taskId = _pathSlug(task.id);
  return [
    p.join('reviews', '$output-$stepId-$taskId.md'),
    p.join('reviews', 'clean-review-$stepId-$taskId.md'),
    p.join('reviews', 'clean-architecture-review-$stepId-$taskId.md'),
  ];
}

String _pathSlug(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');

String? _writeMissingCleanReviewArtifact(
  String claim, {
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required Map<String, dynamic>? workflowContextPayload,
  required String reason,
}) {
  try {
    // TOCTOU note: the containment check in runtimeArtifactsRelativeClaim resolves
    // symlinks at validation time, but the createSync/writeAsStringSync below run
    // separately. A racing process with write access to runtimeArtifactsDir could
    // swap a path component for a symlink in between, redirecting the write outside
    // the run dir. The threat model is bounded: any agent that can win this race
    // already has write access to the run dir (a confused-deputy scenario rather
    // than privilege escalation), and the materialized body is a diagnostic stub –
    // no secrets are leaked. Tightening to O_CREAT|O_EXCL or temp-then-rename is
    // tracked as a hardening item if the threat model widens.
    final file = File(claim)..createSync(recursive: true);
    file.writeAsStringSync(_missingCleanReviewArtifactBody(outputKey, step, task, workflowContextPayload));
    _log.warning('Materialized diagnostic clean review artifact for "$outputKey" on task ${task.id} $reason: $claim');
    return claim;
  } catch (error, st) {
    _log.warning(
      'Failed to materialize diagnostic clean review artifact for "$outputKey" on task ${task.id}: $claim',
      error,
      st,
    );
    return null;
  }
}

String _missingCleanReviewArtifactBody(
  String outputKey,
  WorkflowStep step,
  Task task,
  Map<String, dynamic>? workflowContextPayload,
) {
  final fc = firstIntegerForKeys(workflowContextPayload ?? const {}, findingsCountKeys(step));
  final gc = firstIntegerForKeys(workflowContextPayload ?? const {}, gatingFindingsCountKeys(step));
  return [
    '# Clean Review Artifact',
    '',
    'The agent reported a clean review but did not leave a markdown report on disk.',
    'DartClaw materialized this diagnostic artifact so downstream steps have a durable review path.',
    '',
    '- Step: ${step.id}',
    '- Task: ${task.id}',
    '- Output: $outputKey',
    '- Findings count: ${fc ?? 0}',
    '- Gating findings count: ${gc ?? 0}',
    '',
  ].join('\n');
}
