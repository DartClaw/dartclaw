import 'workflow_run_id_command.dart';

class WorkflowResumeCommand extends WorkflowRunIdCommand {
  WorkflowResumeCommand({
    super.config,
    super.apiClient,
    super.writeLine,
    super.exitFn,
    super.searchDbFactory,
    super.taskDbFactory,
    super.harnessFactory,
    super.environment,
    super.stderrLine,
    super.interrupts,
    super.runWorkflowSkillsBootstrap,
    super.skillIntrospector,
    super.providerAuthPreflight,
  });

  @override
  String get name => 'resume';

  @override
  String get description => 'Resume a paused workflow';

  @override
  Future<void> run() async {
    requireForceWithStandalone();
    final runId = requirePositionalArg('Run ID required');
    if (isStandalone) {
      await runStandaloneLifecycle(
        runId: runId,
        provisionTaskRunners: true,
        action: (session) => driveStandaloneExecution(session, () => session.wiring.workflowService.resume(runId)),
      );
    } else {
      await runAgainstRun(runId: runId, pathSuffix: 'resume', verb: 'resumed');
    }
  }
}
