import 'workflow_run_id_command.dart';

class WorkflowRetryCommand extends WorkflowRunIdCommand {
  WorkflowRetryCommand({super.config, super.apiClient, super.writeLine, super.exitFn});

  @override
  String get name => 'retry';

  @override
  String get description => 'Retry a failed workflow';

  @override
  Future<void> run() => runAgainstRun(pathSuffix: 'retry', verb: 'retried');
}
