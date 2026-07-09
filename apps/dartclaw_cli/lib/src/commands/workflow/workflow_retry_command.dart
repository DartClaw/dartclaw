import 'workflow_run_id_command.dart';

class WorkflowRetryCommand extends WorkflowRunIdCommand {
  WorkflowRetryCommand({
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
  String get name => 'retry';

  @override
  String get description => 'Retry a failed workflow';

  @override
  Future<void> run() async {
    requireForceWithStandalone();
    final runId = requirePositionalArg('Run ID required');
    if (isStandalone) {
      await runStandaloneLifecycle(
        runId: runId,
        provisionTaskRunners: true,
        action: (session) => driveStandaloneExecution(session, () => session.wiring.workflowService.retry(runId)),
      );
    } else {
      await runAgainstRun(runId: runId, pathSuffix: 'retry', verb: 'retried');
    }
  }
}
