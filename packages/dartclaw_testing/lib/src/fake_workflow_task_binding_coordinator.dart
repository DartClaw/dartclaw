import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskBindingCoordinator, WorkflowWorktreeBinding;

/// In-memory [WorkflowTaskBindingCoordinator] for unit tests that exercise
/// workflow-shared worktree hydrate flows without spinning up a real
/// `WorkflowWorktreeBinder` (which would pull in `WorktreeManager`, git
/// processes, and the filesystem).
///
/// Records every hydrated binding keyed by [WorkflowWorktreeBinding.key];
/// expose [bindings] for assertions.
class FakeWorkflowTaskBindingCoordinator implements WorkflowTaskBindingCoordinator {
  final Map<String, WorkflowWorktreeBinding> _bindings = {};

  /// Snapshot of bindings hydrated so far, keyed by
  /// [WorkflowWorktreeBinding.key]. Each call returns a fresh unmodifiable
  /// copy; later [hydrate] calls do not appear in a previously captured
  /// reference.
  Map<String, WorkflowWorktreeBinding> get bindings => Map.unmodifiable(_bindings);

  @override
  void hydrate(WorkflowWorktreeBinding binding) {
    _bindings[binding.key] = binding;
  }
}
