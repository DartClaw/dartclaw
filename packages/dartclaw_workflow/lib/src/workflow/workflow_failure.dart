/// Typed reason a workflow iteration, foreach aggregate or promotion attempt
/// failed.
///
/// [kind] is the discriminator persisted beside a result slot's message, so a
/// resumed run recovers the decision without re-reading operator text. It is
/// part of the persisted contract: renaming a value breaks resume for runs
/// started on an earlier release.
///
/// [message] is operator-facing text carried as payload. Control flow switches
/// on the variant; the message is rendered, never matched.
sealed class WorkflowFailure {
  final String message;

  const new(this.message);

  String get kind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WorkflowFailure && other.runtimeType == runtimeType && other.message == message);

  @override
  int get hashCode => Object.hash(runtimeType, message);

  @override
  String toString() => '$kind($message)';
}

/// A promotion attempt hit a merge conflict, or merge-resolve exhausted on one.
///
/// The one iteration failure that keeps the run's `executionCursor` and leaves
/// its pending dependents re-dispatchable.
final class WorkflowPromotionConflictFailure extends WorkflowFailure {
  static const kindValue = 'promotion-conflict';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// A promotion attempt failed outright, or a promotion prerequisite was missing
/// (no callback, no project binding, no worktree branch, no integration branch,
/// or the unreachable serialize-remaining sentinel on the non-iteration path).
final class WorkflowPromotionFailure extends WorkflowFailure {
  static const kindValue = 'promotion-failure';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// The foreach controller itself failed: budget exhaustion, an unexpected
/// iteration exception, or one of the four zero-item preflight rejections
/// (unresolvable `mapOver`, invalid `maxParallel`, missing child steps,
/// dependency-graph validation).
final class WorkflowForeachControllerFailure extends WorkflowFailure {
  static const kindValue = 'foreach-controller-failure';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// Siblings did not settle inside the serialize-remaining settle timeout.
///
/// The only foreach failure routed to `_failRunAndCancelActiveTasks`.
final class WorkflowSerializeRemainingSettleTimeout extends WorkflowFailure {
  static const kindValue = 'serialize-remaining-settle-timeout';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// Hard iteration failures co-occurred with an escalation-marked blocked item,
/// so the aggregate demands review rather than reporting either alone.
final class WorkflowEscalatedHardFailure extends WorkflowFailure {
  static const kindValue = 'hard-failure-with-escalation';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// An ordinary iteration failure: a failed child step, a task that could not be
/// created, a per-iteration budget stop, or a merge-resolve that returned no
/// result. Carries no recovery path of its own — `onFailure: continue` advances
/// past it.
final class WorkflowIterationFailure extends WorkflowFailure {
  static const kindValue = 'iteration-failure';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// An iteration settled blocked (`needsInput`) and stays retryable.
///
/// The nested-loop escalation marker rides beside this value on the slot's
/// `requires_dependency_hold` key, not inside the kind.
final class WorkflowIterationBlockedHold extends WorkflowFailure {
  static const kindValue = 'iteration-blocked';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// A pending iteration was cancelled by the controller (budget exhaustion,
/// dependency failure, dispatch stall or deadlock).
final class WorkflowIterationCancelled extends WorkflowFailure {
  static const kindValue = 'iteration-cancelled';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// A resumed run's persisted failed slot carries no discriminator this release
/// recognises, so its promotion-conflict recovery path cannot be reconstructed.
///
/// Produced only by iteration restore; keeps the persisted cursor so the failed
/// run still shows where it stopped.
final class WorkflowLegacyIterationStateFailure extends WorkflowFailure {
  static const kindValue = 'legacy-iteration-state';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// Rebuilds a persisted iteration-slot failure from its discriminator.
///
/// Returns null when [kind] is absent or names no variant — a slot written
/// before the typed vocabulary, or by a later release. Callers fail the resume
/// rather than restoring such a slot as an ordinary failure.
WorkflowFailure? workflowFailureFromPersisted(Object? kind, String message) {
  final build = _failureByKind[kind];
  return build == null ? null : build(message);
}

/// Every discriminator [workflowFailureFromPersisted] recognises.
Set<String> get workflowFailureKinds => _failureByKind.keys.toSet();

const _failureByKind = <String, WorkflowFailure Function(String)>{
  WorkflowPromotionConflictFailure.kindValue: WorkflowPromotionConflictFailure.new,
  WorkflowPromotionFailure.kindValue: WorkflowPromotionFailure.new,
  WorkflowForeachControllerFailure.kindValue: WorkflowForeachControllerFailure.new,
  WorkflowSerializeRemainingSettleTimeout.kindValue: WorkflowSerializeRemainingSettleTimeout.new,
  WorkflowEscalatedHardFailure.kindValue: WorkflowEscalatedHardFailure.new,
  WorkflowIterationFailure.kindValue: WorkflowIterationFailure.new,
  WorkflowIterationBlockedHold.kindValue: WorkflowIterationBlockedHold.new,
  WorkflowIterationCancelled.kindValue: WorkflowIterationCancelled.new,
  WorkflowLegacyIterationStateFailure.kindValue: WorkflowLegacyIterationStateFailure.new,
};

/// Typed reason a workflow step attempt failed, chosen by the host that
/// dispatched it.
///
/// The step-retry early stop compares two consecutive values with `==`: equal
/// means the same failure recurred, so the remaining budget is not worth
/// spending. The rule is per-variant and declared here, beside the vocabulary:
///
/// - **Host-classified** variants ([WorkflowOutputValidationFailure],
///   [WorkflowTaskTerminalStatusFailure]) compare on the kind alone. The host
///   chose the kind, so a second miss of the same kind is a repeat however
///   differently its [message] reads.
/// - The **model-declared** variant ([WorkflowModelDeclaredFailure]) compares
///   on kind *and* its verbatim [message]: two different reasons from the model
///   are two different failures, and collapsing them would cap
///   `onFailure: retry` at two attempts.
///
/// Where [message] is compared it is compared exactly — the host never
/// lowercases, strips a prefix from, or truncates it to reach a verdict.
///
/// Separate from [WorkflowFailure] on purpose: these values decide a retry, are
/// never persisted, and never reach an iteration result slot.
sealed class WorkflowStepRetryFailure {
  final String message;

  const new(this.message);

  String get kind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is WorkflowStepRetryFailure && other.runtimeType == runtimeType);

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => '$kind($message)';
}

/// The model declared `outcome: failed`; [message] is its own reason, compared
/// verbatim.
final class WorkflowModelDeclaredFailure extends WorkflowStepRetryFailure {
  static const kindValue = 'model-declared';

  const new(super.message);

  @override
  String get kind => kindValue;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is WorkflowModelDeclaredFailure && other.message == message);

  @override
  int get hashCode => Object.hash(runtimeType, message);
}

/// Post-extraction output validation rejected the attempt — a raised extraction
/// failure, or the story-spec output validator that runs ahead of the catch arms.
final class WorkflowOutputValidationFailure extends WorkflowStepRetryFailure {
  static const kindValue = 'output-validation';

  const new(super.message);

  @override
  String get kind => kindValue;
}

/// The task reached a terminal failure status (`failed` or `rejected`), so the
/// step failed without a model-declared outcome.
///
/// The route by which harness and provider errors, task-level budget
/// exhaustion, guard denials, task-level timeouts and review rejections reach
/// the retry comparison; named for the terminal status because a denial and a
/// rejection are neither crashes.
final class WorkflowTaskTerminalStatusFailure extends WorkflowStepRetryFailure {
  static const kindValue = 'task-terminal-status';

  const new(super.message);

  @override
  String get kind => kindValue;
}
