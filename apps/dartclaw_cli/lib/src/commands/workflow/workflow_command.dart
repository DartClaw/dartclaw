import 'workflow_connection.dart';
import 'api_workflow_connection.dart';

import 'package:args/command_runner.dart';

import 'workflow_cancel_command.dart';
import 'workflow_cleanup_skills_command.dart';
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
  new({WorkflowConnection? connection}) {
    for (final command in workflowSubcommands(
      standaloneOnly: false,
      connection: connection ?? ApiWorkflowConnection(),
    )) {
      addSubcommand(command);
    }
  }

  @override
  String get name => 'workflow';

  @override
  String get description => 'Workflow management commands';
}

List<Command<void>> workflowSubcommands({required bool standaloneOnly, WorkflowConnection? connection}) => [
  WorkflowListCommand(standaloneOnly: standaloneOnly),
  WorkflowCleanupSkillsCommand(),
  WorkflowShowCommand(standaloneOnly: standaloneOnly, connection: connection),
  WorkflowRunCommand(standaloneOnly: standaloneOnly, connection: connection),
  if (!standaloneOnly) WorkflowRunsCommand(),
  WorkflowPauseCommand(standaloneOnly: standaloneOnly, connection: connection),
  WorkflowResumeCommand(standaloneOnly: standaloneOnly, connection: connection),
  WorkflowRetryCommand(standaloneOnly: standaloneOnly, connection: connection),
  WorkflowCancelCommand(standaloneOnly: standaloneOnly, connection: connection),
  WorkflowStatusCommand(standaloneOnly: standaloneOnly, connection: connection),
  WorkflowValidateCommand(),
];
