import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowDefinition;

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

/// Branch bootstrap result for workflow-owned git state.
class WorkflowGitBootstrapResult {
  /// Feature/integration branch that map-item branches promote into.
  final String integrationBranch;

  /// Optional human-readable note about bootstrap behavior.
  final String? note;

  const WorkflowGitBootstrapResult({required this.integrationBranch, this.note});
}

/// Result of promoting a story/task branch into the integration branch.
sealed class WorkflowGitPromotionResult {
  const WorkflowGitPromotionResult();
}

class WorkflowGitPromotionSuccess extends WorkflowGitPromotionResult {
  final String commitSha;

  const WorkflowGitPromotionSuccess({required this.commitSha});
}

class WorkflowGitPromotionConflict extends WorkflowGitPromotionResult {
  final List<String> conflictingFiles;
  final String details;

  const WorkflowGitPromotionConflict({required this.conflictingFiles, required this.details});
}

class WorkflowGitPromotionError extends WorkflowGitPromotionResult {
  final String message;

  const WorkflowGitPromotionError(this.message);
}

/// Result of deterministic workflow publish.
class WorkflowGitPublishResult {
  /// `success`, `manual`, or `failed`.
  final String status;

  /// Branch that was published.
  final String branch;

  /// Remote used for publish (typically `origin`).
  final String remote;

  /// PR URL when available; empty for branch-only publish.
  final String prUrl;

  /// Error detail for failed publish.
  final String? error;

  const WorkflowGitPublishResult({
    required this.status,
    required this.branch,
    required this.remote,
    required this.prUrl,
    this.error,
  });
}

/// Resolved workflow start contract values produced by host-side preflight.
class WorkflowStartResolution {
  /// Effective project id to use for this run.
  final String? projectId;

  /// Effective branch/ref to use for this run.
  final String? branch;

  const WorkflowStartResolution({this.projectId, this.branch});
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
  final Future<WorkflowStartResolution> Function(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    String? projectId,
    bool allowDirtyLocalPath,
  })?
  resolveStartContext;
  final Future<WorkflowGitBootstrapResult> Function({
    required String runId,
    required String projectId,
    required String baseRef,
    required bool perMapItem,
  })?
  bootstrapWorkflowGit;
  final Future<WorkflowGitPromotionResult> Function({
    required String runId,
    required String projectId,
    required String branch,
    required String integrationBranch,
    required String strategy,
    String? storyId,
  })?
  promoteWorkflowBranch;
  final Future<WorkflowGitPublishResult> Function({
    required String runId,
    required String projectId,
    required String branch,
  })?
  publishWorkflowBranch;
  final Future<void> Function({
    required String runId,
    required String projectId,
    required String status,
    required bool preserveWorktrees,
  })?
  cleanupWorkflowGit;
  const WorkflowTurnAdapter({
    required this.reserveTurn,
    this.reserveTurnWithWorkflowWorkspaceDir,
    required this.executeTurn,
    required this.waitForOutcome,
    this.availableRunnerCount,
    this.workflowWorkspaceDir,
    this.resolveStartContext,
    this.bootstrapWorkflowGit,
    this.promoteWorkflowBranch,
    this.publishWorkflowBranch,
    this.cleanupWorkflowGit,
  });
}
