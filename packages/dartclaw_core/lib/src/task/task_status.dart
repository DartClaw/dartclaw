/// Lifecycle states for task orchestration.
enum TaskStatus {
  draft,
  queued,
  running,
  interrupted,
  review,
  accepted,
  rejected,
  cancelled,
  failed;

  static const Map<TaskStatus, Set<TaskStatus>> validTransitions = {
    TaskStatus.draft: {TaskStatus.queued, TaskStatus.cancelled},
    TaskStatus.queued: {TaskStatus.running, TaskStatus.cancelled},
    TaskStatus.running: {TaskStatus.review, TaskStatus.interrupted, TaskStatus.failed, TaskStatus.cancelled},
    TaskStatus.interrupted: {TaskStatus.queued, TaskStatus.cancelled},
    TaskStatus.review: {TaskStatus.accepted, TaskStatus.rejected, TaskStatus.queued},
  };

  /// Whether this state is terminal and has no outbound transitions.
  bool get terminal => switch (this) {
    TaskStatus.accepted || TaskStatus.rejected || TaskStatus.cancelled || TaskStatus.failed => true,
    _ => false,
  };

  /// Returns `true` when [target] is a valid next state.
  bool canTransitionTo(TaskStatus target) => validTransitions[this]?.contains(target) ?? false;
}
