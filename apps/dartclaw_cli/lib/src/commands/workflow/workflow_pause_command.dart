import 'workflow_run_id_command.dart';

class WorkflowPauseCommand extends WorkflowRunIdCommand {
  WorkflowPauseCommand({super.config, super.apiClient, super.writeLine, super.exitFn});

  @override
  String get name => 'pause';

  @override
  String get description => 'Pause a running workflow';

  @override
  Future<void> run() => runAgainstRun(pathSuffix: 'pause', verb: 'paused');
}
