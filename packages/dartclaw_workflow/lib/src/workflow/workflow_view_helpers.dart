import 'package:dartclaw_core/dartclaw_core.dart'
    show Task, TaskStatus, WorkflowDefinition, WorkflowRun, WorkflowRunStatus;

/// Maps a task's status (or absence) to a workflow step status string.
///
/// Status comes from four layers, in precedence order:
/// 1. Step-local outcome markers in `run.contextJson` (for steps with no task,
///    e.g. skipped entryGate branches)
/// 2. Child task lifecycle (`Task.status`) when a task exists
/// 3. `run.currentStepIndex` while the workflow is actively running
/// 4. The workflow run's terminal state
///
/// Shared by the API routes and the workflow UI templates to avoid duplicating
/// this mapping in multiple places.
String stepStatusFromTask(WorkflowRun run, int index, Task? task, {String? stepId}) {
  final contextData = switch (run.contextJson['data']) {
    final Map<String, dynamic> data => data,
    final Map<Object?, Object?> data => Map<String, dynamic>.from(data),
    _ => const <String, dynamic>{},
  };
  final outcome = stepId == null
      ? null
      : (run.contextJson['step.$stepId.outcome'] ?? contextData['step.$stepId.outcome']);
  if (outcome == 'skipped') {
    return 'skipped';
  }
  if (task == null) {
    if (index == run.currentStepIndex && run.status == WorkflowRunStatus.running) {
      return 'running';
    }
    return 'pending';
  }
  return switch (task.status) {
    TaskStatus.draft || TaskStatus.queued => 'queued',
    TaskStatus.running => 'running',
    TaskStatus.review => 'review',
    TaskStatus.accepted => 'completed',
    TaskStatus.failed => 'failed',
    TaskStatus.cancelled => 'cancelled',
    TaskStatus.rejected => 'failed',
    _ => 'pending',
  };
}

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
