/// Lifecycle states for task orchestration.
enum TaskStatus {
  /// Task exists but has not been queued for execution yet.
  draft,

  /// Task is ready to be picked up by an executor.
  queued,

  /// Task is actively being executed.
  running,

  /// Task execution stopped before completion and may be resumed.
  interrupted,

  /// Task completed execution and awaits human review.
  review,

  /// Task was accepted during review.
  accepted,

  /// Task was rejected during review.
  rejected,

  /// Task was cancelled before successful completion.
  cancelled,

  /// Task failed irrecoverably during execution.
  failed;

  static const Map<TaskStatus, Set<TaskStatus>> validTransitions = {
    TaskStatus.draft: {TaskStatus.queued, TaskStatus.cancelled},
    TaskStatus.queued: {TaskStatus.running, TaskStatus.cancelled, TaskStatus.failed},
    TaskStatus.running: {TaskStatus.review, TaskStatus.interrupted, TaskStatus.failed, TaskStatus.cancelled},
    TaskStatus.interrupted: {TaskStatus.queued, TaskStatus.cancelled},
    TaskStatus.review: {
      TaskStatus.accepted,
      TaskStatus.rejected,
      TaskStatus.queued,
      TaskStatus.running,
      TaskStatus.failed,
    },
  };

  /// Whether this state is terminal and has no outbound transitions.
  bool get terminal => switch (this) {
    TaskStatus.accepted || TaskStatus.rejected || TaskStatus.cancelled || TaskStatus.failed => true,
    _ => false,
  };

  /// Returns `true` when [target] is a valid next state.
  bool canTransitionTo(TaskStatus target) => validTransitions[this]?.contains(target) ?? false;
}
