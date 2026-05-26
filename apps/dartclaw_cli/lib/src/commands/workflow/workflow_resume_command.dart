import 'workflow_run_id_command.dart';

class WorkflowResumeCommand extends WorkflowRunIdCommand {
  WorkflowResumeCommand({super.config, super.apiClient, super.writeLine, super.exitFn});

  @override
  String get name => 'resume';

  @override
  String get description => 'Resume a paused workflow';

  @override
  Future<void> run() => runAgainstRun(pathSuffix: 'resume', verb: 'resumed');
}
