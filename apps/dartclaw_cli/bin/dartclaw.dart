import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/agents/agents_command.dart';
import 'package:dartclaw_cli/src/commands/config/config_command.dart';
import 'package:dartclaw_cli/src/commands/deploy/deploy_command.dart';
import 'package:dartclaw_cli/src/commands/google_auth_command.dart';
import 'package:dartclaw_cli/src/commands/init/init_command.dart';
import 'package:dartclaw_cli/src/commands/jobs/jobs_command.dart';
import 'package:dartclaw_cli/src/commands/projects/projects_command.dart';
import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/commands/service/service_command.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/commands/sessions_command.dart';
import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_cli/src/commands/tasks/tasks_command.dart';
import 'package:dartclaw_cli/src/commands/token_command.dart';
import 'package:dartclaw_cli/src/commands/traces/traces_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_command.dart';
import 'package:dartclaw_cli/src/runner.dart';

Future<void> main(List<String> args) async {
  final runner = DartclawRunner()
    ..addCommand(AgentsCommand())
    ..addCommand(ConfigCommand())
    ..addCommand(DeployCommand())
    ..addCommand(GoogleAuthCommand())
    ..addCommand(InitCommand())
    ..addCommand(JobsCommand())
    ..addCommand(SetupAliasCommand())
    ..addCommand(ProjectsCommand())
    ..addCommand(ServiceCommand())
    ..addCommand(ServeCommand())
    ..addCommand(SessionsCommand())
    ..addCommand(StatusCommand())
    ..addCommand(TasksCommand())
    ..addCommand(RebuildIndexCommand())
    ..addCommand(TokenCommand())
    ..addCommand(TracesCommand())
    ..addCommand(WorkflowCommand());

  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64); // EX_USAGE
  }
}
