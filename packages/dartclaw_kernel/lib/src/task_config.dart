import 'execution_policy.dart';

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

  /// const TaskBudgetConfig({this.defaultMaxTokens, this.warningT.
  const new({this.defaultMaxTokens, this.warningThreshold = 0.8});

  /// Default configuration — no budget limits, 80% warning threshold.
  const new defaults() : this();

  /// Whether any default budget is configured.
  bool get hasDefaults => defaultMaxTokens != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskBudgetConfig &&
          defaultMaxTokens == other.defaultMaxTokens &&
          warningThreshold == other.warningThreshold;

  @override
  int get hashCode => Object.hash(defaultMaxTokens, warningThreshold);
}

/// Configuration for the task subsystem.
class TaskConfig {
  /// artifactRetentionDays.
  final int artifactRetentionDays;

  /// completionAction.
  final String completionAction;

  /// worktreeBaseRef.
  final String worktreeBaseRef;

  /// worktreeStaleTimeoutHours.
  final int worktreeStaleTimeoutHours;

  /// worktreeMergeStrategy.
  final String worktreeMergeStrategy;

  /// Per-task token budget configuration.
  final TaskBudgetConfig budget;

  /// Execution-mode fallback for background tasks with no logical-agent identity.
  final ExecutionMode? execution;

  /// Creates a [TaskConfig] value.
  const new({
    this.artifactRetentionDays = 0,
    this.completionAction = 'review',
    this.worktreeBaseRef = 'main',
    this.worktreeStaleTimeoutHours = 24,
    this.worktreeMergeStrategy = 'squash',
    this.budget = const TaskBudgetConfig.defaults(),
    this.execution,
  });

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskConfig &&
          artifactRetentionDays == other.artifactRetentionDays &&
          completionAction == other.completionAction &&
          worktreeBaseRef == other.worktreeBaseRef &&
          worktreeStaleTimeoutHours == other.worktreeStaleTimeoutHours &&
          worktreeMergeStrategy == other.worktreeMergeStrategy &&
          budget == other.budget &&
          execution == other.execution;

  @override
  int get hashCode => Object.hash(
    artifactRetentionDays,
    completionAction,
    worktreeBaseRef,
    worktreeStaleTimeoutHours,
    worktreeMergeStrategy,
    budget,
    execution,
  );
}
