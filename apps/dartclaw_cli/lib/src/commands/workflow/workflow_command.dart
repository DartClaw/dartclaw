import 'package:args/command_runner.dart';

import 'workflow_cancel_command.dart';
import 'workflow_list_command.dart';
import 'workflow_pause_command.dart';
import 'workflow_retry_command.dart';
import 'workflow_run_command.dart';
import 'workflow_runs_command.dart';
import 'workflow_resume_command.dart';
import 'workflow_show_command.dart';
import 'workflow_status_command.dart';
import 'workflow_validate_command.dart';

/// Parent command for workflow management: `dartclaw workflow <subcommand>`.
class WorkflowCommand extends Command<void> {
  WorkflowCommand() {
    addSubcommand(WorkflowListCommand());
    addSubcommand(WorkflowShowCommand());
    addSubcommand(WorkflowRunCommand());
    addSubcommand(WorkflowRunsCommand());
    addSubcommand(WorkflowPauseCommand());
    addSubcommand(WorkflowResumeCommand());
    addSubcommand(WorkflowRetryCommand());
    addSubcommand(WorkflowCancelCommand());
    addSubcommand(WorkflowStatusCommand());
    addSubcommand(WorkflowValidateCommand());
  }

  @override
  String get name => 'workflow';

  @override
  String get description => 'Workflow management commands';
}
