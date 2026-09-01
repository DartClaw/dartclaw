import 'package:dartclaw_core/dartclaw_core.dart'
    show MapIterationCompletedEvent, TaskStatus, WorkflowLifecycleEvent, WorkflowStepCompletedEvent;

import 'workflow_progress_renderer.dart';

/// Decodes one per-run workflow SSE frame into [WorkflowProgressRenderer] calls.
///
/// Only the four progress frame types the CLI renders are decoded. Anything
/// else — a `parallel_group_completed` or `loop_iteration_completed` the web UI
/// owns, an unrecognised future type — is ignored, and a frame that fails to
/// decode is skipped rather than aborting the stream; the run still settles
/// through the caller's post-loop status refetch. A field the wire carries in
/// an unexpected shape makes that field absent, never fatal: a version-skewed
/// server must not crash the client mid-run. `workflow_status_changed` is
/// deliberately not handled here: settle rendering, exit-code mapping and the
/// event-loop break stay lane-owned.
///
/// No core event is synthesized from a partial frame: `TaskStatusChangedEvent`
/// and `WorkflowCliTurnProgressEvent` require fields (`trigger`, `sessionId`,
/// `provider`, per-turn token splits) the wire never carries, so those frames
/// decode into the renderer's own vocabulary instead.
Future<void> renderConnectedWorkflowFrame(Map<String, dynamic> frame, WorkflowProgressRenderer renderer) async {
  switch (frame['type']) {
    case 'task_status_changed':
      final newStatus = _taskStatus(frame['newStatus']);
      if (newStatus == null) return;
      await renderer.taskStatusChanged(
        TaskProgressUpdate(
          taskId: frame['taskId']?.toString(),
          newStatus: newStatus,
          oldStatus: _taskStatus(frame['oldStatus']),
          stepIndex: _int(frame['stepIndex']),
          displayScope: _displayScope(frame),
        ),
      );
    case 'workflow_step_completed':
      final WorkflowStepCompletedEvent completed;
      try {
        completed = WorkflowLifecycleEvent.fromJson(frame) as WorkflowStepCompletedEvent;
      } on FormatException {
        return;
      }
      renderer.stepCompleted(completed, displayScope: _displayScope(frame));
    case 'map_iteration_completed':
      final MapIterationCompletedEvent completed;
      try {
        completed = WorkflowLifecycleEvent.fromJson(frame) as MapIterationCompletedEvent;
      } on FormatException {
        return;
      }
      renderer.mapIterationCompleted(completed, displayScope: _displayScope(frame));
    case 'workflow_cli_turn_progress':
      renderer.turnProgress(taskId: frame['taskId']?.toString(), cumulativeTokens: _int(frame['cumulativeTokens']));
  }
}

int? _int(Object? value) => value is int ? value : null;

TaskStatus? _taskStatus(Object? name) => name == null ? null : TaskStatus.values.asNameMap()[name.toString()];

String? _displayScope(Map<String, dynamic> frame) {
  final scope = frame['displayScope'] ?? frame['itemId'];
  if (scope is! String) return null;
  final trimmed = scope.trim();
  return trimmed.isEmpty ? null : trimmed;
}
