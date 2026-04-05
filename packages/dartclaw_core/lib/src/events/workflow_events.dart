part of 'dartclaw_event.dart';

/// Intermediate sealed type for workflow lifecycle events.
sealed class WorkflowLifecycleEvent extends DartclawEvent {
  /// Identifier of the workflow run associated with the event.
  String get runId;

  @override
  DateTime get timestamp;
}

/// Fired when a workflow run changes status.
final class WorkflowRunStatusChangedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Name of the workflow definition being executed.
  final String definitionName;

  /// Previous status before the transition.
  final WorkflowRunStatus oldStatus;

  /// New status after the transition.
  final WorkflowRunStatus newStatus;

  /// Error message when transitioning to paused or failed.
  final String? errorMessage;

  @override
  final DateTime timestamp;

  WorkflowRunStatusChangedEvent({
    required this.runId,
    required this.definitionName,
    required this.oldStatus,
    required this.newStatus,
    this.errorMessage,
    required this.timestamp,
  });

  @override
  String toString() =>
      'WorkflowRunStatusChangedEvent(run: $runId, ${oldStatus.name} -> ${newStatus.name}'
      '${errorMessage != null ? ', error: $errorMessage' : ''})';
}

/// Fired when a workflow step completes (success or failure).
final class WorkflowStepCompletedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Identifier of the completed step.
  final String stepId;

  /// Human-readable step name.
  final String stepName;

  /// 0-based index of the step in the definition.
  final int stepIndex;

  /// Total number of steps in the definition.
  final int totalSteps;

  /// Identifier of the child task that executed the step.
  final String taskId;

  /// Whether the step completed successfully.
  final bool success;

  /// Tokens consumed by this step.
  final int tokenCount;

  @override
  final DateTime timestamp;

  WorkflowStepCompletedEvent({
    required this.runId,
    required this.stepId,
    required this.stepName,
    required this.stepIndex,
    required this.totalSteps,
    required this.taskId,
    required this.success,
    required this.tokenCount,
    required this.timestamp,
  });

  @override
  String toString() =>
      'WorkflowStepCompletedEvent(run: $runId, step: $stepId [$stepIndex/$totalSteps], '
      'task: $taskId, success: $success, tokens: $tokenCount)';
}

/// Fired when all steps in a parallel group complete (success or partial failure).
final class ParallelGroupCompletedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Step IDs in the parallel group, in definition order.
  final List<String> stepIds;

  /// Number of steps that completed successfully.
  final int successCount;

  /// Number of steps that failed.
  final int failureCount;

  /// Total tokens consumed by all steps in the group.
  final int totalTokens;

  @override
  final DateTime timestamp;

  ParallelGroupCompletedEvent({
    required this.runId,
    required this.stepIds,
    required this.successCount,
    required this.failureCount,
    required this.totalTokens,
    required this.timestamp,
  });

  @override
  String toString() =>
      'ParallelGroupCompletedEvent(run: $runId, steps: ${stepIds.length}, '
      'success: $successCount, failed: $failureCount)';
}

/// Fired when a workflow run's cumulative token consumption reaches the warning threshold.
final class WorkflowBudgetWarningEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Name of the workflow definition.
  final String definitionName;

  /// Fraction of token budget consumed (0.0–1.0+).
  final double consumedPercent;

  /// Actual tokens consumed at time of warning.
  final int consumed;

  /// Token budget limit that is being approached.
  final int limit;

  @override
  final DateTime timestamp;

  WorkflowBudgetWarningEvent({
    required this.runId,
    required this.definitionName,
    required this.consumedPercent,
    required this.consumed,
    required this.limit,
    required this.timestamp,
  });

  @override
  String toString() =>
      'WorkflowBudgetWarningEvent(run: $runId, '
      '${(consumedPercent * 100).toStringAsFixed(0)}% consumed: $consumed/$limit tokens)';
}

/// Fired after each loop iteration completes (whether or not the exit gate passed).
final class LoopIterationCompletedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// ID of the loop definition.
  final String loopId;

  /// Completed iteration number (1-based).
  final int iteration;

  /// Maximum iterations configured for this loop.
  final int maxIterations;

  /// Whether the exit gate passed on this iteration.
  final bool gateResult;

  @override
  final DateTime timestamp;

  LoopIterationCompletedEvent({
    required this.runId,
    required this.loopId,
    required this.iteration,
    required this.maxIterations,
    required this.gateResult,
    required this.timestamp,
  });

  @override
  String toString() =>
      'LoopIterationCompletedEvent(run: $runId, loop: $loopId, '
      'iteration: $iteration/$maxIterations, gate: $gateResult)';
}
