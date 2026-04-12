/// Adapter for the turn execution capabilities used by workflow follow-up prompts.
///
/// This keeps the workflow package independent from the concrete server-side
/// `TurnManager` implementation while still allowing the server and CLI to
/// wire their existing turn infrastructure in.
class WorkflowTurnOutcome {
  /// Normalized turn status name.
  final String status;

  const WorkflowTurnOutcome({required this.status});
}

typedef WorkflowExecuteTurn =
    void Function(
      String sessionId,
      String turnId,
      List<Map<String, dynamic>> messages, {
      required String source,
      required bool resume,
    });

/// Bundle of callbacks required for workflow continuation turns and map-step
/// concurrency budgeting.
class WorkflowTurnAdapter {
  final Future<String> Function(String sessionId) reserveTurn;
  final Future<String> Function(String sessionId, String workflowWorkspaceDir)? reserveTurnWithWorkflowWorkspaceDir;
  final WorkflowExecuteTurn executeTurn;
  final Future<WorkflowTurnOutcome> Function(String sessionId, String turnId) waitForOutcome;
  final int? Function()? availableRunnerCount;
  final String? workflowWorkspaceDir;

  const WorkflowTurnAdapter({
    required this.reserveTurn,
    this.reserveTurnWithWorkflowWorkspaceDir,
    required this.executeTurn,
    required this.waitForOutcome,
    this.availableRunnerCount,
    this.workflowWorkspaceDir,
  });
}
