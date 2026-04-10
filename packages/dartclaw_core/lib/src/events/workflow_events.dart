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

/// Fired when a single iteration of a map/fan-out step completes.
final class MapIterationCompletedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Identifier of the map step.
  final String stepId;

  /// 0-based index of this iteration in the collection.
  final int iterationIndex;

  /// Total number of items in the collection.
  final int totalIterations;

  /// Item's `id` field if present (e.g. "s01"). Null if items have no `id`.
  final String? itemId;

  /// Task that executed this iteration.
  final String taskId;

  /// Whether the iteration completed successfully.
  final bool success;

  /// Tokens consumed by this iteration.
  final int tokenCount;

  @override
  final DateTime timestamp;

  MapIterationCompletedEvent({
    required this.runId,
    required this.stepId,
    required this.iterationIndex,
    required this.totalIterations,
    this.itemId,
    required this.taskId,
    required this.success,
    required this.tokenCount,
    required this.timestamp,
  });

  @override
  String toString() =>
      'MapIterationCompletedEvent(run: $runId, step: $stepId, '
      'iter: $iterationIndex/$totalIterations, task: $taskId, success: $success)';
}

/// Fired when a workflow approval step is reached and the run is paused awaiting human action.
final class WorkflowApprovalRequestedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Identifier of the approval step.
  final String stepId;

  /// Resolved approval message (the step's prompt).
  final String message;

  /// Optional timeout in seconds before the approval auto-cancels.
  final int? timeoutSeconds;

  @override
  final DateTime timestamp;

  WorkflowApprovalRequestedEvent({
    required this.runId,
    required this.stepId,
    required this.message,
    this.timeoutSeconds,
    required this.timestamp,
  });

  @override
  String toString() =>
      'WorkflowApprovalRequestedEvent(run: $runId, step: $stepId'
      '${timeoutSeconds != null ? ', timeout: ${timeoutSeconds}s' : ''})';
}

/// Fired when an approval step is resolved (approved or rejected).
final class WorkflowApprovalResolvedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Identifier of the approval step that was resolved.
  final String stepId;

  /// Whether the approval was accepted (true) or rejected (false).
  final bool approved;

  /// Optional rejection feedback from the operator.
  final String? feedback;

  @override
  final DateTime timestamp;

  WorkflowApprovalResolvedEvent({
    required this.runId,
    required this.stepId,
    required this.approved,
    this.feedback,
    required this.timestamp,
  });

  @override
  String toString() =>
      'WorkflowApprovalResolvedEvent(run: $runId, step: $stepId, '
      'approved: $approved${feedback != null ? ', feedback: $feedback' : ''})';
}

/// Fired when all iterations of a map/fan-out step have settled.
final class MapStepCompletedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Identifier of the map step.
  final String stepId;

  /// Human-readable name of the step.
  final String stepName;

  /// Total number of items in the collection.
  final int totalIterations;

  /// Number of iterations that completed successfully.
  final int successCount;

  /// Number of iterations that failed.
  final int failureCount;

  /// Number of iterations that were cancelled (e.g. due to budget exhaustion).
  final int cancelledCount;

  /// Aggregate tokens consumed across all completed iterations.
  final int totalTokens;

  @override
  final DateTime timestamp;

  MapStepCompletedEvent({
    required this.runId,
    required this.stepId,
    required this.stepName,
    required this.totalIterations,
    required this.successCount,
    required this.failureCount,
    required this.cancelledCount,
    required this.totalTokens,
    required this.timestamp,
  });

  @override
  String toString() =>
      'MapStepCompletedEvent(run: $runId, step: $stepId, '
      'total: $totalIterations, ok: $successCount, fail: $failureCount, '
      'cancelled: $cancelledCount, tokens: $totalTokens)';
}
