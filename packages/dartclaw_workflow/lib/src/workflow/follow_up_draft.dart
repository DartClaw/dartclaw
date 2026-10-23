import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowTaskService;
import 'package:logging/logging.dart';

import 'review_finding_derivations.dart' show asInteger;
import 'review_scoring_fragment.dart' show isGatingSeverity;
import 'workflow_context.dart';
import 'workflow_definition.dart';
import 'workflow_run.dart';

final _log = Logger('FollowUpDraft');

/// Private run-context key holding the run's follow-up draft ([WorkflowFollowUp]).
///
/// Private so it never reaches prompt templating and survives every later
/// write that spreads `privateContextEntries`.
const workflowFollowUpContextKey = '_followUp';

/// The follow-up draft a completed run left behind and how many findings it lists.
typedef WorkflowFollowUp = ({String taskId, int count});

extension WorkflowFollowUpLabel on WorkflowFollowUp {
  /// "1 follow-up" or "N follow-ups": the one wording the run page and the finished post share.
  String get label => '$count follow-up${count == 1 ? '' : 's'}';
}

/// A review finding below the gating severity, carried into a follow-up draft.
typedef FollowUpFinding = ({String severity, String location, String description});

/// The follow-up draft [run] recorded on completion, or `null` when it left none.
///
/// The one reader of [workflowFollowUpContextKey]: the run page, the HTTP API
/// and the finished post all go through it.
WorkflowFollowUp? workflowFollowUp(WorkflowRun run) {
  final entry = run.contextJson[workflowFollowUpContextKey];
  if (entry is! Map) return null;
  final (taskId, count) = (entry['taskId'], entry['count']);
  return taskId is String && count is int ? (taskId: taskId, count: count) : null;
}

/// Task id of [runId]'s follow-up draft. Derived, so a resumed completion finds
/// the draft it already created instead of making a second one.
String workflowFollowUpTaskId(String runId) => 'followup-$runId';

/// The non-gating findings of every `verdict` output [definition] declares, read from the
/// final [context] (top-level keys, and foreach iteration results for steps inside a foreach).
///
/// A verdict is superseded, and contributes nothing, when its own step emitted
/// `gating_findings_count > 0`: that model-written count is what the remediation
/// loops gate on, and a remediated verdict is replaced by the re-review's. A
/// step that declares no count keeps its verdict.
List<FollowUpFinding> collectFollowUpFindings(WorkflowDefinition definition, WorkflowContext context) {
  final findings = <FollowUpFinding>[];
  for (final step in definition.steps) {
    final outputs = step.outputs ?? const <String, OutputConfig>{};
    final countKey = outputs.entries.where((e) => e.value.presetName == 'gating_findings_count').firstOrNull?.key;
    for (final verdictKey in [
      for (final e in outputs.entries)
        if (e.value.presetName == 'verdict') e.key,
    ]) {
      for (final stepOutputs in _stepOutputs(definition, step, context)) {
        if ((asInteger(stepOutputs[countKey]) ?? 0) > 0) continue;
        final verdict = stepOutputs[verdictKey];
        if (verdict is! Map || verdict['findings'] is! List) continue;
        for (final finding in verdict['findings'] as List) {
          if (finding is! Map) continue;
          final severity = finding['severity'];
          if (severity is! String || isGatingSeverity(severity)) continue;
          findings.add((
            severity: severity,
            location: '${finding['location'] ?? ''}',
            description: '${finding['description'] ?? ''}',
          ));
        }
      }
    }
  }
  return findings;
}

/// The output maps [step] produced: one for a top-level step, one per
/// iteration for a foreach child (failed iterations hold an error slot, not outputs).
Iterable<Map<Object?, Object?>> _stepOutputs(
  WorkflowDefinition definition,
  WorkflowStep step,
  WorkflowContext context,
) {
  final controller = definition.steps
      .where((s) => s.isForeachController && s.foreachSteps!.contains(step.id))
      .firstOrNull;
  if (controller == null) return [context.data];
  final results = controller.outputKeys.isEmpty ? null : context[controller.outputKeys.first];
  return [
    if (results is List)
      for (final result in results)
        if (result is Map && result[step.id] is Map) result[step.id] as Map<Object?, Object?>,
  ];
}

/// Creates [run]'s one follow-up draft task listing [findings], for an admin to start from the task page.
///
/// The draft is an ordinary task: no `workflowRunId`, so review lists, accept/merge and workflow git
/// cleanup leave it alone. It never starts itself, since its text is model-written and may derive
/// from untrusted content. A task already holding the derived id counts as created. Returns `null`
/// after logging when creation fails: a follow-up must not fail a completed run, and is not retried.
Future<WorkflowFollowUp?> createFollowUpDraft({
  required WorkflowRun run,
  required List<FollowUpFinding> findings,
  required WorkflowTaskService taskService,
  String? projectId,
}) async {
  final taskId = workflowFollowUpTaskId(run.id);
  try {
    if (await taskService.get(taskId) == null) {
      await taskService.create(
        id: taskId,
        title: 'Review follow-ups from ${run.definitionName}',
        description: _draftDescription(run, findings),
        createdBy: 'workflow',
        projectId: projectId,
        configJson: {'followUpOfRunId': run.id},
      );
    }
    return (taskId: taskId, count: findings.length);
  } catch (e, st) {
    _log.warning("Workflow '${run.definitionName}' (${run.id}): follow-up draft not created: $e", e, st);
    return null;
  }
}

String _draftDescription(WorkflowRun run, List<FollowUpFinding> findings) {
  final inputs = [
    for (final key in const ['TARGET', 'FEATURE', 'BRANCH', 'PR_NUMBER'])
      if (run.variablesJson[key]?.trim() case final value? when value.isNotEmpty) '- $key: $value',
  ];
  return [
    'Address the review findings below. They fell under the gating severity, so workflow run ${run.id} '
        '(${run.definitionName}) completed without fixing them. Run page: /workflows/${run.id}',
    if (inputs.isNotEmpty) 'Run inputs:\n${inputs.join('\n')}',
    'Findings:\n${findings.map((f) => '- [${f.severity}] ${f.location}: ${f.description}').join('\n')}',
  ].join('\n\n');
}
