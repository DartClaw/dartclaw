import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/deploy/deploy_command.dart';
import 'package:dartclaw_cli/src/commands/google_auth_command.dart';
import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/commands/sessions_command.dart';
import 'package:dartclaw_cli/src/commands/status_command.dart';
import 'package:dartclaw_cli/src/commands/token_command.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_command.dart';
import 'package:dartclaw_cli/src/runner.dart';

Future<void> main(List<String> args) async {
  final runner =
      DartclawRunner()
        ..addCommand(DeployCommand())
        ..addCommand(GoogleAuthCommand())
        ..addCommand(ServeCommand())
        ..addCommand(SessionsCommand())
        ..addCommand(StatusCommand())
        ..addCommand(RebuildIndexCommand())
        ..addCommand(TokenCommand())
        ..addCommand(WorkflowCommand());

  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64); // EX_USAGE
  }
}
