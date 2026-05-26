import 'dart:io';

import 'package:path/path.dart' as p;

import 'review_finding_derivations.dart' show asInteger;
import 'schema_presets.dart' show isReviewReportPathPreset;
import 'workflow_context.dart';
import 'workflow_definition.dart' show OutputConfig, OutputFormat, WorkflowDefinition, WorkflowStep, WorkflowTaskType;
import 'workflow_run.dart' show WorkflowRun;
import 'workflow_run_paths.dart' show workflowRuntimeArtifactsDir;
import 'workflow_runner_types.dart' show StepOutcome;

/// Executes a `type: aggregate-reviews` step on the host.
Future<StepOutcome> executeAggregateStep({
  required WorkflowRun run,
  required WorkflowDefinition definition,
  required WorkflowStep step,
  required WorkflowContext context,
  required String dataDir,
  String? activeWorkspaceRoot,
}) async {
  if (step.taskType != WorkflowTaskType.aggregateReviews) {
    throw StateError('aggregate runner received non-aggregate step ${step.id} (type: ${step.taskType.toJson()})');
  }

  final sections = <String>[];
  var findingsCount = 0;
  var gatingFindingsCount = 0;
  final stepsById = {for (final candidate in definition.steps) candidate.id: candidate};

  for (final sourceId in step.aggregateReviews ?? const <String>[]) {
    findingsCount += asInteger(context['$sourceId.findings_count']) ?? 0;
    gatingFindingsCount += asInteger(context['$sourceId.gating_findings_count']) ?? 0;

    final sourceStep = stepsById[sourceId];
    final reportKey = sourceStep == null ? null : reviewReportPathOutputKey(sourceStep);
    final reportBody = reportKey == null ? null : _readReportBody(context[reportKey], activeWorkspaceRoot);
    sections.add('# $sourceId\n\n${reportBody ?? '_no report produced by ${sourceId}_'}\n');
  }

  final mergedPath = aggregatedReviewReportPath(run: run, step: step, context: context, dataDir: dataDir);
  final mergedFile = File(mergedPath);
  mergedFile.parent.createSync(recursive: true);
  await mergedFile.writeAsString('${sections.join('\n')}\n');

  return StepOutcome(
    step: step,
    outputs: {
      'review_findings': mergedPath,
      'findings_count': findingsCount,
      'gating_findings_count': gatingFindingsCount,
      '${step.id}.status': 'success',
      '${step.id}.tokenCount': 0,
    },
    tokenCount: 0,
    success: true,
  );
}

/// Returns the deterministic merged report path for [step] in [run].
String aggregatedReviewReportPath({
  required WorkflowRun run,
  required WorkflowStep step,
  required WorkflowContext context,
  required String dataDir,
}) {
  final configured = context.systemVariable('workflow.runtime_artifacts_dir')?.trim();
  final runtimeArtifactsDir = configured == null || configured.isEmpty
      ? workflowRuntimeArtifactsDir(dataDir: dataDir, runId: run.id)
      : configured;
  return p.normalize(p.absolute(runtimeArtifactsDir, 'reviews', 'aggregated-${step.id}.md'));
}

/// Returns the context key carrying [step]'s single review report path output.
///
/// Returns `null` when zero or more than one review-report path outputs are
/// declared. The validator rejects both shapes at load time, so the
/// runner's null-handling (rendering a missing-source placeholder) is a
/// defensive fallback for unvalidated workflows.
String? reviewReportPathOutputKey(WorkflowStep step) {
  String? foundKey;
  for (final entry in step.outputs?.entries ?? const Iterable<MapEntry<String, OutputConfig>>.empty()) {
    if (entry.value.format != OutputFormat.path || !isReviewReportPathPreset(entry.value.presetName)) continue;
    if (foundKey != null) return null;
    foundKey = entry.key;
  }
  return foundKey;
}

String? _readReportBody(Object? pathValue, String? activeWorkspaceRoot) {
  final path = pathValue?.toString().trim();
  if (path == null || path.isEmpty) return null;
  final workspaceRoot = activeWorkspaceRoot?.trim();
  final resolvedPath = p.isAbsolute(path) || workspaceRoot == null || workspaceRoot.isEmpty
      ? path
      : p.join(workspaceRoot, path);
  final file = File(resolvedPath);
  if (!file.existsSync()) return null;
  try {
    return file.readAsStringSync().trimRight();
  } on FileSystemException {
    return null;
  }
}
