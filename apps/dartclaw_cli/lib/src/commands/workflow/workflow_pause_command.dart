import 'workflow_run_id_command.dart';

class WorkflowPauseCommand extends WorkflowRunIdCommand {
  WorkflowPauseCommand({
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
    super.runAndthenSkillsBootstrap,
    super.skillIntrospector,
    super.providerAuthPreflight,
  });

  @override
  String get name => 'pause';

  @override
  String get description => 'Pause a running workflow';

  @override
  Future<void> run() async {
    requireForceWithStandalone();
    final runId = requirePositionalArg('Run ID required');
    if (isStandalone) {
      await runStandaloneLifecycle(
        runId: runId,
        provisionTaskRunners: false,
        runAndthenSkillsBootstrap: false,
        action: (session) async {
          final paused = await session.wiring.workflowService.pause(runId);
          printLifecycleStatus(paused, 'paused');
          return 0;
        },
      );
    } else {
      await runAgainstRun(runId: runId, pathSuffix: 'pause', verb: 'paused');
    }
  }
}
