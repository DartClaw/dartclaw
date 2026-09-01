import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task;

import 'workflow_definition.dart' show WorkflowStep;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'output_resolver.dart';
import 'path_safety_policy.dart' show validateArgumentSafePath;
import 'review_finding_derivations.dart' show firstIntegerForKeys;

final _log = Logger('ContextExtractor');

/// Returns the context keys that carry a findings count for [step].
List<String> findingsCountKeys(WorkflowStep step) => ['${step.id}.findings_count', 'findings_count'];

/// Returns the context keys that carry a gating-findings count for [step].
List<String> gatingFindingsCountKeys(WorkflowStep step) => [
  '${step.id}.gating_findings_count',
  'gating_findings_count',
];

/// The findings count [step] reported, or null when it reported none.
///
/// Read from the step's own payload under its canonical count keys — the
/// schema-enforced integers the model emitted. Nothing is derived here: a step
/// that emits no count reported no count.
int? reportedFindingsCount(WorkflowStep step, Map<String, dynamic> claimPayload) =>
    firstIntegerForKeys(claimPayload, findingsCountKeys(step));

/// Returns true when [step] reported a review with no findings at all.
///
/// A clean review that left no report on disk still owes downstream steps a
/// durable path, which [materializeUnclaimedCleanReviewArtifact] provides.
bool reportedCleanReview(WorkflowStep step, Map<String, dynamic> claimPayload) {
  final fc = reportedFindingsCount(step, claimPayload);
  if (fc != 0) return false;
  final gc = firstIntegerForKeys(claimPayload, gatingFindingsCountKeys(step));
  return gc == null || gc == 0;
}

/// Captures the artifacts a step left in its host-owned artifacts dir for the
/// path output declaring [resolver], or null when the dir yields no candidate.
///
/// The host exports `DARTCLAW_STEP_ARTIFACTS_DIR` on every workflow task, so the
/// directory — not a model's transcription of a path — is the source of truth
/// for an unclaimed artifact. Selection is entirely declarative: the output's
/// own [FileSystemOutput.pathPattern] filters the dir's top-level files by
/// basename, [FileSystemOutput.preferPatterns] breaks a tie, and
/// most-recently-modified is the final tie-break. No output key, preset name or
/// filename convention is consulted.
///
/// The dir is host-created but agent-writable, so two candidate filters are not
/// negotiable: symlinks are not followed (a link planted here would resolve to
/// an arbitrary host path), and a candidate whose basename is not argument-safe
/// is skipped, because the returned value is absolute and therefore exempt from
/// [ContextExtractor]'s downstream argument-safety check before it is
/// interpolated into a skill's command line.
///
/// Returned paths are always absolute (an engine-owned root). A list output
/// gets every match; a singular output gets exactly one.
List<String>? captureStepArtifact(
  String stepArtifactsDir,
  FileSystemOutput resolver, {
  required String outputKey,
  required String? taskId,
}) {
  final dir = Directory(stepArtifactsDir);
  if (!dir.existsSync()) return null;
  final candidates = <({String path, DateTime modified})>[
    for (final entity in dir.listSync(followLinks: false))
      if (entity is File && resolver.matches(p.basename(entity.path)) && _argumentSafeBasename(entity.path, outputKey))
        (path: p.normalize(entity.path), modified: entity.statSync().modified),
  ];
  if (candidates.isEmpty) return null;
  if (resolver.listMode) return (candidates.map((c) => c.path).toList()..sort());
  if (candidates.length == 1) return <String>[candidates.single.path];

  final paths = candidates.map((c) => c.path).toList()..sort();
  final preferred = _preferredSingularMatch(resolver.preferPatterns, paths);
  if (preferred != null) return <String>[preferred];

  candidates.sort((a, b) => b.modified.compareTo(a.modified));
  _log.warning(
    'Multiple artifacts in $stepArtifactsDir matched "$outputKey" on task $taskId; '
    'selecting most recent (${p.basename(candidates.first.path)}).',
  );
  return <String>[candidates.first.path];
}

/// Whether a captured candidate's basename is safe to interpolate into a skill
/// command line. Reuses the one argument-safety authority rather than restating
/// its rules; a rejected candidate is skipped, never returned.
bool _argumentSafeBasename(String path, String outputKey) {
  final basename = p.basename(path);
  try {
    validateArgumentSafePath(basename, fieldName: outputKey, rawPath: basename);
    return true;
  } on FormatException catch (error) {
    _log.warning('Ignoring step artifact with an unsafe name for "$outputKey": ${error.message}');
    return false;
  }
}

/// Picks a single winner from [matches] using the output's declared
/// [FileSystemOutput.preferPatterns]: the first bare basename (compared
/// case-insensitively) with exactly one matching candidate wins. Returns null
/// when no preference resolves a unique match, leaving the ambiguity to the
/// caller's tie-break.
String? _preferredSingularMatch(List<String> preferPatterns, List<String> matches) {
  for (final basename in preferPatterns) {
    final lowered = basename.toLowerCase();
    final hits = matches.where((match) => p.basename(match).toLowerCase() == lowered).toList()..sort();
    if (hits.length == 1) return hits.single;
  }
  return null;
}

/// Writes a diagnostic artifact into the step artifacts dir when a clean
/// review leaves no report on disk.
String? materializeUnclaimedCleanReviewArtifact({
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required Map<String, dynamic> claimPayload,
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
    claimPayload: claimPayload,
    reason: 'after the agent reported zero findings without leaving a report',
  );
}

String _pathSlug(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');

String? _writeMissingCleanReviewArtifact(
  String claim, {
  required String outputKey,
  required WorkflowStep step,
  required Task task,
  required Map<String, dynamic> claimPayload,
  required String reason,
}) {
  try {
    // The stub path is host-computed (never model-claimed), so no containment
    // validation applies. A racing process with write access to the run dir
    // could still symlink-swap a path component between create and write, but
    // that actor already holds write access there (confused-deputy, not
    // privilege escalation) and the body is a diagnostic stub — no secrets.
    final file = File(claim)..createSync(recursive: true);
    file.writeAsStringSync(_missingCleanReviewArtifactBody(outputKey, step, task, claimPayload));
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
  Map<String, dynamic> claimPayload,
) {
  final fc = firstIntegerForKeys(claimPayload, findingsCountKeys(step));
  final gc = firstIntegerForKeys(claimPayload, gatingFindingsCountKeys(step));
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
