/// Configuration for per-task token budget enforcement.
///
/// Provides global defaults for tasks that don't specify their own budget.
/// Parsed from the `tasks.budget.*` YAML section.
class TaskBudgetConfig {
  /// Default maximum token budget per task. Null = no default limit.
  final int? defaultMaxTokens;

  /// Percentage threshold (0.0–1.0) at which budget warning fires.
  ///
  /// At this threshold, a `BudgetWarningEvent` fires and a system message is
  /// injected warning the agent to wrap up.
  final double warningThreshold;

  const TaskBudgetConfig({this.defaultMaxTokens, this.warningThreshold = 0.8});

  /// Default configuration — no budget limits, 80% warning threshold.
  const TaskBudgetConfig.defaults() : this();

  /// Whether any default budget is configured.
  bool get hasDefaults => defaultMaxTokens != null;
}

/// Configuration for the task subsystem.
class TaskConfig {
  final int maxConcurrent;
  final int artifactRetentionDays;
  final String completionAction;
  final String worktreeBaseRef;
  final int worktreeStaleTimeoutHours;
  final String worktreeMergeStrategy;

  /// Per-task token budget configuration.
  final TaskBudgetConfig budget;

  const TaskConfig({
    this.maxConcurrent = 3,
    this.artifactRetentionDays = 0,
    this.completionAction = 'review',
    this.worktreeBaseRef = 'main',
    this.worktreeStaleTimeoutHours = 24,
    this.worktreeMergeStrategy = 'squash',
    this.budget = const TaskBudgetConfig.defaults(),
  });

  /// Default configuration.
  const TaskConfig.defaults() : this();
}
