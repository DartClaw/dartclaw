import 'package:dartclaw_core/dartclaw_core.dart'
    show Task, TaskStatus, WorkflowDefinition, WorkflowRun, WorkflowRunStatus;

/// Maps a task's status (or absence) to a workflow step status string.
///
/// Shared by the API routes (S05) and the workflow UI templates (S11, S12)
/// to avoid duplicating this mapping in multiple places.
String stepStatusFromTask(WorkflowRun run, int index, Task? task) {
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
