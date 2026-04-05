import 'package:args/command_runner.dart';

import 'workflow_list_command.dart';
import 'workflow_run_command.dart';
import 'workflow_status_command.dart';

/// Parent command for workflow management: `dartclaw workflow <subcommand>`.
class WorkflowCommand extends Command<void> {
  WorkflowCommand() {
    addSubcommand(WorkflowListCommand());
    addSubcommand(WorkflowRunCommand());
    addSubcommand(WorkflowStatusCommand());
  }

  @override
  String get name => 'workflow';

  @override
  String get description => 'Workflow management commands';
}
