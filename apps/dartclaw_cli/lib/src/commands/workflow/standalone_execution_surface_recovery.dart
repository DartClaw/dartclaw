import 'package:dartclaw_kernel/dartclaw_kernel.dart' show WorkflowRunStatus, scrubAgentReportedText;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowExecutionSurfaceHold, WorkflowRun;

WorkflowExecutionSurfaceHold? standaloneExecutionSurfaceHold(WorkflowRun run) => switch (run.status) {
  WorkflowRunStatus.awaitingApproval || WorkflowRunStatus.paused => WorkflowExecutionSurfaceHold.read(run.contextJson),
  _ => null,
};

/// The hold's operation, destination, worktrees and every held path, one scrubbed value per line.
List<String> executionSurfaceHoldLines(WorkflowExecutionSurfaceHold hold) => [
  'Execution-surface review is required to ${hold.publish ? 'publish' : 'promote'} '
      'branch ${scrubAgentReportedText(hold.branch)}.',
  if (hold.destination case final destination?) 'Destination ${scrubAgentReportedText(destination)}',
  if (hold.worktreePath case final path?) 'Source worktree ${scrubAgentReportedText(path)}',
  if (hold.destinationWorktreePath case final path? when path != hold.worktreePath)
    'Destination worktree ${scrubAgentReportedText(path)}',
  'Review these paths in the workflow repository.',
  for (final path in hold.paths) '  ${scrubAgentReportedText(path)}',
];

List<String> standaloneExecutionSurfaceRecoveryLines(WorkflowExecutionSurfaceHold? hold) => [
  if (hold != null) ...executionSurfaceHoldLines(hold),
  'Use `git worktree list` from the workflow repository to find the relevant checkouts.',
  'Review and save your work before cancelling. You can complete the reviewed Git operation manually.',
  'To use DartClaw approval, start a fresh run in connected mode. The server cannot resume this standalone run.',
];
