import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskStatus;

import 'workflow_definition.dart' show WorkflowDefinition, WorkflowStep;
import 'workflow_run.dart' show WorkflowRun;

/// Maps a task's status (or absence) to a workflow step status string.
///
/// Status comes from four layers, in precedence order:
/// 1. A skipped step-local outcome marker in `run.contextJson`
/// 2. Child task lifecycle (`Task.status`) when a task exists
/// 3. Producer-owned context status for a taskless step
/// 4. `run.currentStepIndex` while the workflow is actively running; otherwise
///    the step is pending
///
/// Shared by the API routes and the workflow UI templates to avoid duplicating
/// this mapping in multiple places.
String stepStatusFromTask(WorkflowRun run, int index, Task? task, {String? stepId}) {
  final outcome = stepId == null ? null : workflowContextValue(run, 'step.$stepId.outcome');
  if (outcome == 'skipped') {
    return 'skipped';
  }
  if (outcome == 'failed') {
    return 'failed';
  }
  if (task == null) {
    final approvalStatus = stepId == null ? null : workflowContextValue(run, '$stepId.approval.status');
    final projectedApprovalStatus = switch (approvalStatus) {
      'pending' || 'waiting' || 'awaiting_approval' => 'awaiting_approval',
      'approved' || 'completed' => 'completed',
      'rejected' => 'rejected',
      'changes_requested' => 'changes_requested',
      'expired' || 'timed_out' => 'timed_out',
      _ => null,
    };
    if (projectedApprovalStatus != null) return projectedApprovalStatus;

    final persistedStatus = stepId == null ? null : workflowContextValue(run, '$stepId.status');
    final projectedPersistedStatus = switch (persistedStatus) {
      'success' || 'accepted' || 'completed' => 'completed',
      'failed' => 'failed',
      'cancelled' => 'cancelled',
      _ => null,
    };
    if (projectedPersistedStatus != null) return projectedPersistedStatus;
    if (index == run.currentStepIndex && run.status == WorkflowRunStatus.running) {
      return 'running';
    }
    return 'pending';
  }
  return switch (task.status) {
    TaskStatus.draft || TaskStatus.queued => 'queued',
    TaskStatus.running => 'running',
    TaskStatus.interrupted => 'interrupted',
    TaskStatus.review => 'review',
    TaskStatus.accepted => 'completed',
    TaskStatus.failed => 'failed',
    TaskStatus.cancelled => 'cancelled',
    TaskStatus.rejected => 'failed',
  };
}

/// Reads a workflow context value from either the persisted data map or the
/// legacy flat run snapshot.
Object? workflowContextValue(WorkflowRun run, String key) => run.contextJson[key] ?? _contextData(run)[key];

/// Builds a short operator-facing summary of run-level `blocked` (recoverable)
/// step outcomes from a persisted run's context, or null when none exist.
///
/// A foreach controller that advances past escalated items with no open
/// dependent records `step.<id>.outcome = 'blocked'`; the run then completes
/// green while a story shipped unresolved. The summary makes that gap
/// surfaceable on operator-facing rollups without re-gating the run.
String? workflowBlockedOutcomeSummary(WorkflowRun run) {
  final contextData = _contextData(run);
  final pattern = RegExp(r'^step\.(.+)\.outcome$');
  final lines = <String>[];
  for (final entry in contextData.entries) {
    if (entry.value != 'blocked') continue;
    final match = pattern.firstMatch(entry.key);
    if (match == null) continue;
    final stepId = match.group(1)!;
    final reason = contextData['step.$stepId.outcome.reason'];
    lines.add(reason is String && reason.trim().isNotEmpty ? reason.trim() : "Step '$stepId' ended blocked.");
  }
  if (lines.isEmpty) return null;
  lines.sort();
  return lines.join('\n');
}

Map<String, dynamic> _contextData(WorkflowRun run) => switch (run.contextJson['data']) {
  final Map<String, dynamic> data => data,
  final Map<Object?, Object?> data => Map<String, dynamic>.from(data),
  _ => const <String, dynamic>{},
};

/// Builds loop membership info for all loops in a workflow definition.
///
/// Returns a list of maps, one per loop, with loop ID, step IDs,
/// max iterations, and current iteration (from context JSON).
List<Map<String, dynamic>> buildLoopInfo(WorkflowDefinition definition, Map<String, dynamic> contextJson) {
  return definition.loops.map((loop) {
    final iterationKey = 'loop.${loop.id}.iteration';
    return <String, dynamic>{
      'loopId': loop.id,
      'stepIds': loop.steps,
      'maxIterations': loop.maxIterations,
      'currentIteration': (contextJson[iterationKey] as num?)?.toInt() ?? 0,
    };
  }).toList();
}

String workflowStatusLabel(WorkflowRunStatus status) => switch (status) {
  WorkflowRunStatus.pending => 'Pending',
  WorkflowRunStatus.running => 'Running',
  WorkflowRunStatus.paused => 'Paused',
  WorkflowRunStatus.awaitingApproval => 'Awaiting approval',
  WorkflowRunStatus.completed => 'Completed',
  WorkflowRunStatus.failed => 'Failed',
  WorkflowRunStatus.cancelled => 'Cancelled',
};

String workflowStatusBadgeClass(WorkflowRunStatus status) => switch (status) {
  WorkflowRunStatus.awaitingApproval => 'status-badge-awaiting-approval',
  _ => 'status-badge-${status.name}',
};

bool workflowCanRetry(WorkflowRun run) => run.status == WorkflowRunStatus.failed;

bool workflowCanResume(WorkflowRun run) => run.status == WorkflowRunStatus.paused;

bool workflowCanApprove(WorkflowRun run) =>
    run.status == WorkflowRunStatus.awaitingApproval && run.contextJson['_approval.pending.stepId'] != null;

bool workflowCanReject(WorkflowRun run) =>
    run.status == WorkflowRunStatus.awaitingApproval && run.contextJson['_approval.pending.stepId'] != null;

/// How many request-changes rounds a pending gate has used out of its bound.
class WorkflowRevisionState {
  /// Rounds already requested at the gate.
  final int count;

  /// The gate's bound on rounds.
  final int max;

  /// Creates a state.
  const new({required this.count, required this.max});

  /// Whether another round may be requested.
  bool get isOpen => count < max;
}

/// The revision state of the approval [run] is pending at, or `null` when it is
/// pending at none, or at a step that names no `revise` step.
///
/// The one answer to whether request changes is on offer: the owner, the
/// interaction issue, `workflow_status`, the run page and the HTTP route all read it.
WorkflowRevisionState? workflowRevisionState(WorkflowRun run) {
  final stepId = run.contextJson['_approval.pending.stepId'];
  if (stepId is! String) return null;
  final rawSteps = run.definitionJson['steps'];
  if (rawSteps is! List) return null;
  final stepJson = rawSteps.whereType<Map<Object?, Object?>>().where((step) => step['id'] == stepId).firstOrNull;
  if (stepJson == null) return null;
  final max = WorkflowStep.fromJson(Map<String, dynamic>.from(stepJson)).effectiveMaxRevisions;
  if (max == null) return null;
  final count = workflowContextValue(run, '$stepId.approval.revision');
  return WorkflowRevisionState(count: count is num ? count.toInt() : 0, max: max);
}

/// Formats context JSON for display, filtering internal keys and truncating long values.
List<Map<String, dynamic>> formatContextForDisplay(Map<String, dynamic> contextJson) {
  return contextJson.entries.where((e) => !e.key.startsWith('_') && !e.key.startsWith('loop.')).map((e) {
    final value = e.value?.toString() ?? '';
    return <String, dynamic>{
      'key': e.key,
      'value': value.length > 500 ? '${value.substring(0, 500)}...' : value,
      'isLong': value.length > 200,
    };
  }).toList();
}
