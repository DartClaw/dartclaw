import 'package:args/command_runner.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowApprovalRefusal, WorkflowApprovalRefused, WorkflowExecutionSurfaceHold;

import 'standalone_execution_surface_recovery.dart';
import 'workflow_run_id_command.dart';

class WorkflowResumeCommand extends WorkflowRunIdCommand {
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
  }) {
    if (!standaloneOnly) {
      argParser.addOption('candidate', help: 'Approve the execution-surface candidate shown by connected status');
    }
  }

  @override
  String get name => 'resume';

  @override
  String get description => 'Resume a paused workflow';

  @override
  Future<void> run() async {
    requireForceWithStandalone();
    final runId = requirePositionalArg('Run ID required');
    final candidate = standaloneOnly ? null : argResults!.option('candidate');
    if (isStandalone) {
      if (candidate != null) throw UsageException('--candidate requires connected mode', usage);
      await runStandaloneLifecycle(
        runId: runId,
        provisionWorkers: true,
        preflightRun: (run) {
          if (standaloneExecutionSurfaceHold(run) case final hold?) _refuseStandaloneHold(hold);
        },
        action: (session) => driveStandaloneExecution(session, () async {
          final service = session.runtime.workflowService;
          try {
            return await service.resume(runId);
          } on WorkflowApprovalRefused catch (error) {
            if (error.reason != WorkflowApprovalRefusal.personRequired) rethrow;
            final currentRun = await service.get(runId);
            _refuseStandaloneHold(currentRun == null ? null : standaloneExecutionSurfaceHold(currentRun));
          }
        }),
      );
    } else {
      await runAgainstRun(runId: runId, pathSuffix: 'resume', verb: 'resumed', executionSurfaceCandidate: candidate);
    }
  }

  Never _refuseStandaloneHold(WorkflowExecutionSurfaceHold? hold) {
    stderrLine('Standalone resume cannot approve execution-surface changes.');
    for (final line in standaloneExecutionSurfaceRecoveryLines(hold)) {
      stderrLine(line);
    }
    exitFn(1);
  }
}
