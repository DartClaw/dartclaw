part of 'dartclaw_event.dart';

/// Intermediate sealed type for workflow lifecycle events.
sealed class WorkflowLifecycleEvent extends DartclawEvent {
  /// Identifier of the workflow run associated with the event.
  String get runId;

  @override
  DateTime get timestamp;

  Map<String, dynamic> toJson();

  static WorkflowLifecycleEvent fromJson(Map<String, dynamic> json) {
    final type = _requiredString(json, 'type');
    return switch (type) {
      'workflow_status_changed' => WorkflowRunStatusChangedEvent.fromJson(json),
      'workflow_step_completed' => WorkflowStepCompletedEvent.fromJson(json),
      'parallel_group_completed' => ParallelGroupCompletedEvent.fromJson(json),
      'workflow_budget_warning' => WorkflowBudgetWarningEvent.fromJson(json),
      'loop_iteration_completed' => LoopIterationCompletedEvent.fromJson(json),
      'map_iteration_completed' => MapIterationCompletedEvent.fromJson(json),
      'approval_requested' || 'workflow_approval_requested' => WorkflowApprovalRequestedEvent.fromJson(json),
      'approval_resolved' || 'workflow_approval_resolved' => WorkflowApprovalResolvedEvent.fromJson(json),
      'map_step_completed' => MapStepCompletedEvent.fromJson(json),
      'workflow_serialization_enacted' => WorkflowSerializationEnactedEvent.fromJson(json),
      'step_skipped' => StepSkippedEvent.fromJson(json),
      _ => throw FormatException('Unknown workflow lifecycle event type "$type"'),
    };
  }
}

/// Fired when a workflow run changes status.
// NOT_ALERTABLE: workflow lifecycle telemetry — surfaced via SSE only
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

  factory WorkflowRunStatusChangedEvent.fromJson(Map<String, dynamic> json) => WorkflowRunStatusChangedEvent(
    runId: _requiredString(json, 'runId'),
    definitionName: _optionalString(json, 'definitionName') ?? '',
    oldStatus: _workflowRunStatus(json, 'oldStatus'),
    newStatus: _workflowRunStatus(json, 'newStatus'),
    errorMessage: _optionalString(json, 'errorMessage'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'workflow_status_changed',
    'runId': runId,
    'oldStatus': oldStatus.name,
    'newStatus': newStatus.name,
    'errorMessage': errorMessage,
  });

  @override
  String toString() =>
      'WorkflowRunStatusChangedEvent(run: $runId, ${oldStatus.name} -> ${newStatus.name}'
      '${errorMessage != null ? ', error: $errorMessage' : ''})';
}

/// Fired when a workflow step completes (success or failure).
// NOT_ALERTABLE: workflow lifecycle telemetry — surfaced via SSE only
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

  /// Optional short label that scopes repeated step executions.
  final String? displayScope;

  /// Whether the step completed successfully.
  final bool success;

  /// Semantic outcome the executor recorded for the step (`succeeded`,
  /// `failed`, `needsInput`/`blocked`, `skipped`), or null when the emit site
  /// has no per-step outcome (aggregate/cancelled events).
  final String? outcome;

  /// Human-readable reason the step settled with this [outcome], or null when
  /// none was recorded. For a failed or blocked step this is the operator-facing
  /// explanation surfaced inline in the console.
  final String? reason;

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
    this.displayScope,
    required this.success,
    this.outcome,
    this.reason,
    required this.tokenCount,
    required this.timestamp,
  });

  factory WorkflowStepCompletedEvent.fromJson(Map<String, dynamic> json) {
    final stepId = _requiredString(json, 'stepId');
    return WorkflowStepCompletedEvent(
      runId: _requiredString(json, 'runId'),
      stepId: stepId,
      stepName: _optionalString(json, 'stepName') ?? stepId,
      stepIndex: _requiredInt(json, 'stepIndex'),
      totalSteps: _requiredInt(json, 'totalSteps'),
      taskId: _requiredString(json, 'taskId'),
      displayScope: _optionalString(json, 'displayScope'),
      success: _requiredBool(json, 'success'),
      outcome: _optionalString(json, 'outcome'),
      reason: _optionalString(json, 'reason'),
      tokenCount: _requiredInt(json, 'tokenCount'),
      timestamp: _timestampFromJson(json),
    );
  }

  /// [stepName] is deliberately not transported (the wire shape predates it);
  /// [WorkflowStepCompletedEvent.fromJson] falls back to [stepId], so
  /// round-trips are JSON-equal but not object-equal when the two differ.
  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'workflow_step_completed',
    'runId': runId,
    'stepId': stepId,
    'stepIndex': stepIndex,
    'totalSteps': totalSteps,
    'taskId': taskId,
    'displayScope': displayScope,
    'success': success,
    'outcome': outcome,
    'reason': reason,
    'tokenCount': tokenCount,
  });

  @override
  String toString() =>
      'WorkflowStepCompletedEvent(run: $runId, step: $stepId [$stepIndex/$totalSteps], '
      'task: $taskId${displayScope != null ? ', scope: $displayScope' : ''}, '
      'success: $success${outcome != null ? ', outcome: $outcome' : ''}, tokens: $tokenCount)';
}

/// Fired when a workflow-owned one-shot CLI provider finishes a turn.
// NOT_ALERTABLE: workflow progress telemetry — surfaced via SSE only
final class WorkflowCliTurnProgressEvent extends DartclawEvent {
  /// Task whose workflow-owned CLI invocation emitted the progress signal.
  final String taskId;

  /// DartClaw session that owns the workflow task.
  final String sessionId;

  /// Provider ID (`codex`, `claude`, ...).
  final String provider;

  /// 1-based turn index within the one-shot invocation.
  final int turnIndex;

  /// Cumulative provider-reported tokens after this turn completed.
  final int cumulativeTokens;

  /// Raw provider-reported cumulative input tokens.
  final int inputTokens;

  /// Raw provider-reported cumulative output tokens.
  final int outputTokens;

  /// Raw provider-reported cumulative cache-read tokens.
  final int cacheReadTokens;

  /// Raw provider-reported cumulative cache-write tokens.
  final int cacheWriteTokens;

  @override
  final DateTime timestamp;

  WorkflowCliTurnProgressEvent({
    required this.taskId,
    required this.sessionId,
    required this.provider,
    required this.turnIndex,
    required this.cumulativeTokens,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.timestamp,
  });

  @override
  String toString() =>
      'WorkflowCliTurnProgressEvent(task: $taskId, provider: $provider, '
      'turn: $turnIndex, cumulative: $cumulativeTokens)';
}

final class WorkflowCliStallEvent extends DartclawEvent {
  final String provider;
  final String stepName;
  final Duration silentDuration;
  final String action;

  @override
  final DateTime timestamp;

  WorkflowCliStallEvent({
    required this.provider,
    required this.stepName,
    required this.silentDuration,
    required this.action,
    required this.timestamp,
  });

  @override
  String toString() =>
      'WorkflowCliStallEvent(provider: $provider, step: $stepName, silentDuration: $silentDuration, action: $action)';
}

/// Fired when all steps in a parallel group complete (success or partial failure).
// NOT_ALERTABLE: workflow lifecycle telemetry — surfaced via SSE only
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

  factory ParallelGroupCompletedEvent.fromJson(Map<String, dynamic> json) => ParallelGroupCompletedEvent(
    runId: _requiredString(json, 'runId'),
    stepIds: _requiredStringList(json, 'stepIds'),
    successCount: _requiredInt(json, 'successCount'),
    failureCount: _requiredInt(json, 'failureCount'),
    totalTokens: _requiredInt(json, 'totalTokens'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'parallel_group_completed',
    'runId': runId,
    'stepIds': stepIds,
    'successCount': successCount,
    'failureCount': failureCount,
    'totalTokens': totalTokens,
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

  factory WorkflowBudgetWarningEvent.fromJson(Map<String, dynamic> json) => WorkflowBudgetWarningEvent(
    runId: _requiredString(json, 'runId'),
    definitionName: _requiredString(json, 'definitionName'),
    consumedPercent: _requiredDouble(json, 'consumedPercent'),
    consumed: _requiredInt(json, 'consumed'),
    limit: _requiredInt(json, 'limit'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'workflow_budget_warning',
    'runId': runId,
    'definitionName': definitionName,
    'consumedPercent': consumedPercent,
    'consumed': consumed,
    'limit': limit,
    'timestamp': timestamp.toIso8601String(),
  });

  @override
  String toString() =>
      'WorkflowBudgetWarningEvent(run: $runId, '
      '${(consumedPercent * 100).toStringAsFixed(0)}% consumed: $consumed/$limit tokens)';
}

/// Fired after each loop iteration completes (whether or not the exit gate passed).
// NOT_ALERTABLE: workflow loop telemetry — surfaced via SSE only
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

  factory LoopIterationCompletedEvent.fromJson(Map<String, dynamic> json) => LoopIterationCompletedEvent(
    runId: _requiredString(json, 'runId'),
    loopId: _requiredString(json, 'loopId'),
    iteration: _requiredInt(json, 'iteration'),
    maxIterations: _requiredInt(json, 'maxIterations'),
    gateResult: _requiredBool(json, 'gateResult'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'loop_iteration_completed',
    'runId': runId,
    'loopId': loopId,
    'iteration': iteration,
    'maxIterations': maxIterations,
    'gateResult': gateResult,
  });

  @override
  String toString() =>
      'LoopIterationCompletedEvent(run: $runId, loop: $loopId, '
      'iteration: $iteration/$maxIterations, gate: $gateResult)';
}

/// Fired when a single iteration of a map/fan-out step completes.
// NOT_ALERTABLE: progress telemetry — surfaced via SSE only
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

  /// Semantic outcome the executor recorded for the iteration's child step
  /// (`succeeded`, `failed`, `needsInput`/`blocked`), or null for aggregate/
  /// cancelled events with no per-child outcome.
  final String? outcome;

  /// Human-readable reason the iteration settled with this [outcome], or null
  /// when none was recorded. Surfaced inline for failed/blocked iterations.
  final String? reason;

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
    this.outcome,
    this.reason,
    required this.tokenCount,
    required this.timestamp,
  });

  factory MapIterationCompletedEvent.fromJson(Map<String, dynamic> json) => MapIterationCompletedEvent(
    runId: _requiredString(json, 'runId'),
    stepId: _requiredString(json, 'stepId'),
    iterationIndex: _requiredInt(json, 'iterationIndex'),
    totalIterations: _requiredInt(json, 'totalIterations'),
    itemId: _optionalString(json, 'itemId'),
    taskId: _requiredString(json, 'taskId'),
    success: _requiredBool(json, 'success'),
    outcome: _optionalString(json, 'outcome'),
    reason: _optionalString(json, 'reason'),
    tokenCount: _requiredInt(json, 'tokenCount'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'map_iteration_completed',
    'runId': runId,
    'stepId': stepId,
    'iterationIndex': iterationIndex,
    'totalIterations': totalIterations,
    'itemId': itemId,
    'displayScope': itemId,
    'taskId': taskId,
    'success': success,
    'outcome': outcome,
    'reason': reason,
    'tokenCount': tokenCount,
  });

  @override
  String toString() =>
      'MapIterationCompletedEvent(run: $runId, step: $stepId, '
      'iter: $iterationIndex/$totalIterations, task: $taskId, success: $success'
      '${outcome != null ? ', outcome: $outcome' : ''})';
}

/// Fired when a workflow approval step requests a decision.
// NOT_ALERTABLE: workflow approval telemetry — surfaced via SSE only
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

  factory WorkflowApprovalRequestedEvent.fromJson(Map<String, dynamic> json) => WorkflowApprovalRequestedEvent(
    runId: _requiredString(json, 'runId'),
    stepId: _requiredString(json, 'stepId'),
    message: _requiredString(json, 'message'),
    timeoutSeconds: _optionalInt(json, 'timeoutSeconds'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'approval_requested',
    'runId': runId,
    'stepId': stepId,
    'message': message,
    'timeoutSeconds': timeoutSeconds,
    'timestamp': timestamp.toIso8601String(),
  });

  @override
  String toString() =>
      'WorkflowApprovalRequestedEvent(run: $runId, step: $stepId'
      '${timeoutSeconds != null ? ', timeout: ${timeoutSeconds}s' : ''})';
}

/// Fired when an approval step is resolved (approved or rejected).
// NOT_ALERTABLE: workflow approval telemetry — surfaced via SSE only
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

  factory WorkflowApprovalResolvedEvent.fromJson(Map<String, dynamic> json) => WorkflowApprovalResolvedEvent(
    runId: _requiredString(json, 'runId'),
    stepId: _requiredString(json, 'stepId'),
    approved: _requiredBool(json, 'approved'),
    feedback: _optionalString(json, 'feedback'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'approval_resolved',
    'runId': runId,
    'stepId': stepId,
    'approved': approved,
    'feedback': feedback,
    'timestamp': timestamp.toIso8601String(),
  });

  @override
  String toString() =>
      'WorkflowApprovalResolvedEvent(run: $runId, step: $stepId, '
      'approved: $approved${feedback != null ? ', feedback: $feedback' : ''})';
}

/// Fired when all iterations of a map/fan-out step have settled.
// NOT_ALERTABLE: progress telemetry — surfaced via SSE only
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

  /// Number of iterations that settled blocked (`needsInput`, recoverable),
  /// distinct from a hard failure. Defaults to 0 for callers that do not track
  /// blocked items.
  final int blockedCount;

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
    this.blockedCount = 0,
    required this.totalTokens,
    required this.timestamp,
  });

  factory MapStepCompletedEvent.fromJson(Map<String, dynamic> json) => MapStepCompletedEvent(
    runId: _requiredString(json, 'runId'),
    stepId: _requiredString(json, 'stepId'),
    stepName: _requiredString(json, 'stepName'),
    totalIterations: _requiredInt(json, 'totalIterations'),
    successCount: _requiredInt(json, 'successCount'),
    failureCount: _requiredInt(json, 'failureCount'),
    cancelledCount: _requiredInt(json, 'cancelledCount'),
    blockedCount: _optionalInt(json, 'blockedCount') ?? 0,
    totalTokens: _requiredInt(json, 'totalTokens'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'map_step_completed',
    'runId': runId,
    'stepId': stepId,
    'stepName': stepName,
    'totalIterations': totalIterations,
    'successCount': successCount,
    'failureCount': failureCount,
    'cancelledCount': cancelledCount,
    'blockedCount': blockedCount,
    'totalTokens': totalTokens,
  });

  @override
  String toString() =>
      'MapStepCompletedEvent(run: $runId, step: $stepId, '
      'total: $totalIterations, ok: $successCount, fail: $failureCount, '
      'blocked: $blockedCount, cancelled: $cancelledCount, tokens: $totalTokens)';
}

/// Fired once per workflow run when a merge-conflict escalation first triggers
/// serialize-remaining mode for any foreach step — parallel execution of that
/// step is halted and remaining iterations will run serially.
///
/// Exactly one event is emitted per run: if multiple foreach
/// steps in the same run each escalate, only the first emits this event;
/// subsequent steps still enter serial mode but do not re-emit. The
/// [foreachStepId] field identifies the step that triggered the run-level
/// transition.
// NOT_ALERTABLE: workflow governance telemetry — surfaced via SSE only
final class WorkflowSerializationEnactedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Identifier of the foreach step that entered serial mode.
  final String foreachStepId;

  /// Zero-based index of the iteration whose merge conflict triggered escalation.
  final int failingIterationIndex;

  /// Attempt number (1-based) of the failing merge attempt.
  final int failedAttemptNumber;

  @override
  final DateTime timestamp;

  WorkflowSerializationEnactedEvent({
    required this.runId,
    required this.foreachStepId,
    required this.failingIterationIndex,
    required this.failedAttemptNumber,
    required this.timestamp,
  });

  factory WorkflowSerializationEnactedEvent.fromJson(Map<String, dynamic> json) => WorkflowSerializationEnactedEvent(
    runId: _requiredString(json, 'runId'),
    foreachStepId: _requiredString(json, 'foreachStepId'),
    failingIterationIndex: _requiredInt(json, 'failingIterationIndex'),
    failedAttemptNumber: _requiredInt(json, 'failedAttemptNumber'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'workflow_serialization_enacted',
    'runId': runId,
    'foreachStepId': foreachStepId,
    'failingIterationIndex': failingIterationIndex,
    'failedAttemptNumber': failedAttemptNumber,
    'timestamp': timestamp.toIso8601String(),
  });

  @override
  String toString() =>
      'WorkflowSerializationEnactedEvent(run: $runId, step: $foreachStepId, '
      'failingIter: $failingIterationIndex, attempt: $failedAttemptNumber)';
}

/// Fired when a workflow step is skipped because its [entryGate] expression
/// evaluated false.
///
/// The cursor advances past the step without pausing the run.
// NOT_ALERTABLE: workflow control-flow telemetry — surfaced via SSE only
final class StepSkippedEvent extends WorkflowLifecycleEvent {
  @override
  final String runId;

  /// Identifier of the skipped step.
  final String stepId;

  /// The entryGate expression that evaluated false.
  final String reason;

  @override
  final DateTime timestamp;

  StepSkippedEvent({required this.runId, required this.stepId, required this.reason, required this.timestamp});

  factory StepSkippedEvent.fromJson(Map<String, dynamic> json) => StepSkippedEvent(
    runId: _requiredString(json, 'runId'),
    stepId: _requiredString(json, 'stepId'),
    reason: _requiredString(json, 'reason'),
    timestamp: _timestampFromJson(json),
  );

  @override
  Map<String, dynamic> toJson() => _workflowEventJson({
    'type': 'step_skipped',
    'runId': runId,
    'stepId': stepId,
    'reason': reason,
    'timestamp': timestamp.toIso8601String(),
  });

  @override
  String toString() => 'StepSkippedEvent(run: $runId, step: $stepId, reason: "$reason")';
}

Map<String, dynamic> _workflowEventJson(Map<String, dynamic> values) => {
  for (final entry in values.entries)
    if (entry.value != null) entry.key: entry.value,
};

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected string field "$key"');
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  throw FormatException('Expected string field "$key"');
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = _optionalInt(json, key);
  if (value != null) {
    return value;
  }
  throw FormatException('Expected integer field "$key"');
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num && value.truncateToDouble() == value) {
    return value.toInt();
  }
  throw FormatException('Expected integer field "$key"');
}

double _requiredDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is num) {
    return value.toDouble();
  }
  throw FormatException('Expected numeric field "$key"');
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Expected boolean field "$key"');
}

List<String> _requiredStringList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is List) {
    return value.map((entry) {
      if (entry is String) {
        return entry;
      }
      throw FormatException('Expected string list field "$key"');
    }).toList();
  }
  throw FormatException('Expected string list field "$key"');
}

DateTime _timestampFromJson(Map<String, dynamic> json) {
  final value = json['timestamp'];
  if (value == null) {
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
  if (value is String) {
    return DateTime.parse(value);
  }
  throw const FormatException('Expected timestamp string field "timestamp"');
}

WorkflowRunStatus _workflowRunStatus(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  for (final status in WorkflowRunStatus.values) {
    if (status.name == value) {
      return status;
    }
  }
  throw FormatException('Unknown workflow run status "$value"');
}
