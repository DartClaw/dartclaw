import 'workflow_run.dart' show WorkflowWorktreeBinding;

/// Cross-package contract for hydrating persisted workflow-shared worktree
/// bindings into the running task layer.
///
/// The concrete implementation lives in `dartclaw_server`
/// (`WorkflowWorktreeBinder`); the workflow package depends on this interface
/// to invoke the hydrate callback on resume/retry without referencing
/// `WorktreeInfo`, which is server-resident and would violate the
/// `dartclaw_core` ↛ `dartclaw_server` dependency direction.
///
/// Server-only operations (resolving, accessing, or awaiting the underlying
/// `WorktreeInfo`) intentionally remain on the concrete class — they require
/// types that cannot cross this boundary.
abstract interface class WorkflowTaskBindingCoordinator {
  /// Records a persisted [binding] so subsequent task processing for the
  /// owning workflow run can reuse the bound worktree without recreating it.
  ///
  /// The binding's own [WorkflowWorktreeBinding.workflowRunId] is the single
  /// source of truth for run identity; the workflow layer asserts
  /// persisted-data integrity before invoking this method.
  void hydrate(WorkflowWorktreeBinding binding);
}
