import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'workflow_run.dart' show WorkflowRun, WorkflowWorktreeBinding;

/// Storage-agnostic contract for workflow-run persistence.
abstract interface class WorkflowRunRepository {
  /// Inserts a new workflow run.
  Future<void> insert(WorkflowRun run);

  /// Returns the workflow run with [id], or null when missing.
  Future<WorkflowRun?> getById(String id);

  /// Lists workflow runs ordered by newest first.
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName});

  /// Persists an update when supplied status and timestamp preconditions match.
  ///
  /// Returns `false` when the run is missing or its status has changed.
  Future<bool> update(WorkflowRun run, {WorkflowRunStatus? expectedStatus, DateTime? expectedUpdatedAt});

  /// Changes lifecycle fields without replacing concurrently persisted progress.
  ///
  /// Returns the updated run, or null if [expectedStatus] no longer matches.
  Future<WorkflowRun?> transitionStatus(
    String id, {
    required WorkflowRunStatus expectedStatus,
    required WorkflowRunStatus status,
    DateTime? completedAt,
  });

  /// Deletes a workflow run by id.
  Future<void> delete(String id);

  /// Upserts a worktree [binding] for a workflow run.
  Future<void> setWorktreeBinding(String runId, WorkflowWorktreeBinding binding);

  /// Returns the latest workflow worktree binding for [runId], if present.
  Future<WorkflowWorktreeBinding?> getWorktreeBinding(String runId);

  /// Returns all workflow worktree bindings for [runId].
  Future<List<WorkflowWorktreeBinding>> getWorktreeBindings(String runId);
}

/// Status observations for runs controlled by another process.
abstract interface class WorkflowRunChangeSource {
  /// Emits the current status and subsequent changes until cancelled or terminal.
  Stream<WorkflowRunStatus> watchStatus(String runId);
}

/// The executor lost its persisted right to advance a workflow run.
final class WorkflowRunOwnershipLost implements Exception {
  /// Run whose status changed before a write.
  final String runId;

  /// Creates a conflict for [runId].
  new(this.runId);

  @override
  String toString() => 'Workflow run ownership lost: $runId';
}

/// Conditional writes made by an active workflow executor.
extension WorkflowRunOwnership on WorkflowRunRepository {
  /// Refuses to overwrite a run whose status changed under another controller.
  Future<void> updateOwned(WorkflowRun run, {WorkflowRunStatus expectedStatus = WorkflowRunStatus.running}) async {
    if (!await update(run, expectedStatus: expectedStatus)) throw WorkflowRunOwnershipLost(run.id);
  }
}
