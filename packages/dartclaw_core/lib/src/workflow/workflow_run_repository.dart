import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowRun, WorkflowRunStatus, WorkflowWorktreeBinding;

/// Storage-agnostic contract for workflow-run persistence.
abstract interface class WorkflowRunRepository {
  /// Inserts a new workflow run.
  Future<void> insert(WorkflowRun run);

  /// Returns the workflow run with [id], or null when missing.
  Future<WorkflowRun?> getById(String id);

  /// Lists workflow runs ordered by newest first.
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName});

  /// Persists an update to an existing workflow run.
  Future<void> update(WorkflowRun run);

  /// Deletes a workflow run by id.
  Future<void> delete(String id);

  /// Upserts a worktree [binding] for a workflow run.
  Future<void> setWorktreeBinding(String runId, WorkflowWorktreeBinding binding);

  /// Returns the latest workflow worktree binding for [runId], if present.
  Future<WorkflowWorktreeBinding?> getWorktreeBinding(String runId);

  /// Returns all workflow worktree bindings for [runId].
  Future<List<WorkflowWorktreeBinding>> getWorktreeBindings(String runId);
}
