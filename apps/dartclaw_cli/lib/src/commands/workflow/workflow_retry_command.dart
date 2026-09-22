import 'workflow_run_id_command.dart';

class WorkflowRetryCommand extends WorkflowRunIdCommand {
  new({
    super.standaloneOnly,
    super.reachabilityProbe,
    super.config,
    super.connection,
    super.writeLine,
    super.exitFn,
    super.taskBackendFactory,
    super.taskBackendIsPrepared,
    super.taskRepositoryFactory,
    super.workflowRunRepositoryFactory,
    super.agentExecutionRepositoryFactory,
    super.workflowStepExecutionRepositoryFactory,
    super.executionRepositoryTransactorFactory,
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
        provisionWorkers: true,
        action: (session) => driveStandaloneExecution(session, () => session.runtime.workflowService.retry(runId)),
      );
    } else {
      await runAgainstRun(runId: runId, pathSuffix: 'retry', verb: 'retried');
    }
  }
}
