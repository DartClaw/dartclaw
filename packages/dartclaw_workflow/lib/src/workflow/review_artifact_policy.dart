import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'workflow_definition.dart' show OutputFormat, WorkflowStep;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'missing_artifact_failure.dart';
import 'output_resolver.dart';
import 'review_finding_derivations.dart' show firstIntegerForKeys;
import 'schema_presets.dart' show isReviewReportPathPreset;
import 'workflow_run_paths.dart';

final _log = Logger('ContextExtractor');

/// Returns true if the output key represents a review artifact path output.
///
/// A key qualifies when its [OutputConfig] declares `format: path` AND the
/// output declares the `review_report_path` preset, the step declares
/// review-count keys, the payload already contains review counts, or the
/// resolver's pattern contains "review" or "architecture". Preset declaration
/// is the name-agnostic signal — the `review_report_path` preset itself resolves
/// the uniform `**/*` glob, so review-artifact recognition cannot rely on a
/// name-keyed pattern.
bool isReviewArtifactPathOutput(
  String outputKey,
  WorkflowStep step,
  FileSystemOutput resolver,
  Map<String, dynamic>? workflowContextPayload,
) {
  final config = step.outputs?[outputKey];
  if (config?.format != OutputFormat.path) return false;
  return isReviewReportPathPreset(config?.presetName) ||
      declaresReviewCounts(step) ||
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

/// Captures a review artifact deterministically from the host-owned step
/// artifacts dir, ignoring model-claimed paths.
///
/// The host exports `DARTCLAW_STEP_ARTIFACTS_DIR` on every workflow task and
/// the review skill writes its report there, so the directory — not the
/// model's transcription of a path — is the source of truth. The newest
/// top-level `.md` file wins (warning when multiple are present; loop
/// occurrences share the step dir). The returned path is always absolute.
///
/// When the dir holds no report:
/// - zero reported findings → materializes the diagnostic stub in the step dir
///   (downstream steps are guaranteed a durable `review_report_path`)
/// - otherwise → throws [MissingArtifactFailure] (honest failure).
Object resolveReviewArtifactFromStepDir({
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required FileSystemOutput resolver,
  required Map<String, dynamic>? workflowContextPayload,
  required String dataDir,
  required int? mapIterationIndex,
}) {
  final runId = task.workflowRunId?.trim();
  final stepArtifactsDir = runId == null || runId.isEmpty
      ? null
      : workflowStepArtifactsDir(dataDir: dataDir, runId: runId, stepId: step.id, mapIterationIndex: mapIterationIndex);
  final located = stepArtifactsDir == null
      ? null
      : _newestMarkdownArtifact(stepArtifactsDir, outputKey: outputKey, taskId: task.id);
  if (located != null) return resolver.listMode ? <String>[located] : located;

  if (allowsMissingCleanReviewArtifact(outputKey, step, resolver, workflowContextPayload)) {
    final stub = stepArtifactsDir == null
        ? null
        : materializeUnclaimedCleanReviewArtifact(
            outputKey: outputKey,
            step: step,
            task: task,
            workflowContextPayload: workflowContextPayload,
            stepArtifactsDir: stepArtifactsDir,
          );
    if (stub != null) return resolver.listMode ? <String>[stub] : stub;
    _log.warning(
      'No review artifact found in the step artifacts dir for clean review "$outputKey" on task ${task.id}; '
      'returning empty instead of matching unrelated files.',
    );
    return resolver.listMode ? const <String>[] : '';
  }
  throw MissingArtifactFailure(
    claimedPaths: const [],
    missingPaths: [?stepArtifactsDir],
    worktreePath: (task.worktreeJson?['path'] as String?)?.trim() ?? '',
    fieldName: outputKey,
    reason: 'no review artifact found in the step artifacts dir',
  );
}

/// Returns the absolute path of the most-recently-modified top-level `.md`
/// file in [stepArtifactsDir], or null when none exists. Non-`.md` files an
/// agent drops in its dir are ignored.
String? _newestMarkdownArtifact(String stepArtifactsDir, {required String outputKey, required String taskId}) {
  final dir = Directory(stepArtifactsDir);
  if (!dir.existsSync()) return null;
  final candidates = <({String path, DateTime modified})>[
    for (final entity in dir.listSync())
      if (entity is File && entity.path.toLowerCase().endsWith('.md'))
        (path: p.normalize(entity.path), modified: entity.statSync().modified),
  ];
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.modified.compareTo(a.modified));
  if (candidates.length > 1) {
    _log.warning(
      'Multiple review artifacts in $stepArtifactsDir for "$outputKey" on task $taskId; '
      'selecting most recent (${p.basename(candidates.first.path)}).',
    );
  }
  return candidates.first.path;
}

/// Writes a diagnostic artifact into the step artifacts dir when a clean
/// review leaves no report on disk.
String? materializeUnclaimedCleanReviewArtifact({
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required Map<String, dynamic>? workflowContextPayload,
  required String stepArtifactsDir,
}) {
  try {
    Directory(stepArtifactsDir).createSync(recursive: true);
  } on FileSystemException catch (error, st) {
    _log.warning('Failed to create clean review artifact directory for "$outputKey" on task ${task.id}', error, st);
    return null;
  }
  final claim = p.join(stepArtifactsDir, 'clean-review-${_pathSlug(step.id)}-${_pathSlug(task.id)}.md');
  return _writeMissingCleanReviewArtifact(
    claim,
    outputKey: outputKey,
    step: step,
    task: task,
    workflowContextPayload: workflowContextPayload,
    reason: 'after the agent reported zero findings without leaving a report',
  );
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
    // The stub path is host-computed (never model-claimed), so no containment
    // validation applies. A racing process with write access to the run dir
    // could still symlink-swap a path component between create and write, but
    // that actor already holds write access there (confused-deputy, not
    // privilege escalation) and the body is a diagnostic stub — no secrets.
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
