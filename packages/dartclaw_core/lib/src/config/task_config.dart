/// Configuration for the task subsystem.
class TaskConfig {
  final int maxConcurrent;
  final int artifactRetentionDays;
  final String completionAction;
  final String worktreeBaseRef;
  final int worktreeStaleTimeoutHours;
  final String worktreeMergeStrategy;

  const TaskConfig({
    this.maxConcurrent = 3,
    this.artifactRetentionDays = 0,
    this.completionAction = 'review',
    this.worktreeBaseRef = 'main',
    this.worktreeStaleTimeoutHours = 24,
    this.worktreeMergeStrategy = 'squash',
  });

  /// Default configuration.
  const TaskConfig.defaults() : this();
}
