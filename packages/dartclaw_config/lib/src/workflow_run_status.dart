/// Lifecycle states for a workflow execution.
enum WorkflowRunStatus {
  /// Workflow created but not yet started.
  pending,

  /// Workflow is actively executing steps.
  running,

  /// Workflow deliberately paused by an operator.
  paused,

  /// Workflow is waiting for human approval or additional input.
  awaitingApproval,

  /// All steps completed successfully.
  completed,

  /// Workflow failed irrecoverably.
  failed,

  /// Workflow was cancelled by user.
  cancelled;

  /// Whether this is a terminal state.
  bool get terminal => switch (this) {
    WorkflowRunStatus.completed || WorkflowRunStatus.failed || WorkflowRunStatus.cancelled => true,
    _ => false,
  };
}
