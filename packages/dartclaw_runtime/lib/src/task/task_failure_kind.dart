part of 'task_budget_policy.dart';

/// Why a task failed, named by the call site that observed the failure.
///
/// Retry deduplication compares [key]: two consecutive attempts failing under
/// the same key stop the retry loop, so genuinely different reasons must carry
/// different keys.
sealed class TaskFailureKind {
  /// Discriminator persisted with the task and compared on the next attempt.
  String get key;
}

/// A failure the host classified itself, without an exception to inspect.
enum TaskFailureReason implements TaskFailureKind {
  projectSetup,
  missingArtifactInput,
  sessionMissing,
  absentPrompt,
  readOnlyMutation,
  budgetExceeded,
  loopDetected,
  workflowOneShot,
  turnFailure,
  worktreeBinding,
  containerCrash;

  @override
  String get key => name;
}

/// A failure carrying an exception object.
///
/// The exception's runtime type is the discriminator; its message never is —
/// two occurrences of one defect must read as the same reason even when their
/// messages differ, and two different defects must not collapse into one.
final class TaskExecutionFailure implements TaskFailureKind {
  new(Object error) : typeName = error.runtimeType.toString();

  final String typeName;

  @override
  String get key => 'exception:$typeName';
}

/// A runner-attributed turn-budget breach.
enum TaskLimitFailure implements TaskFailureKind {
  stall,
  turnTimeout;

  factory fromBreach(TurnLimitBreach breach) => switch (breach) {
    TurnLimitBreach.stall => stall,
    TurnLimitBreach.turnTimeout => turnTimeout,
  };

  @override
  String get key => switch (this) {
    stall => 'limit:stall',
    turnTimeout => 'limit:turn-timeout',
  };
}

/// `configJson` key carrying the previous attempt's [TaskFailureKind.key].
///
/// Written only where it is read — the retry branch — so a task that never
/// retried leaves none behind. A permanent failure leaves the last key in
/// place; `TaskActionService.start` clears it when an operator restarts the
/// failed task, so the fresh run compares against its own attempts. The leading
/// underscore puts it inside the reserved-key space the create-task route
/// refuses, so a client cannot pre-poison a task's retry.
const lastFailureKindKey = '_lastFailureKind';
