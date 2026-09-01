import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;

import 'commands/auth/auth_command.dart';
import 'commands/config/config_command.dart';
import 'commands/google_auth_command.dart';
import 'commands/init/init_command.dart';
import 'commands/jobs/jobs_command.dart';
import 'commands/projects/projects_command.dart';
import 'commands/rebuild_index_command.dart';
import 'commands/runners/runners_command.dart';
import 'commands/secrets/secrets_command.dart';
import 'commands/serve_command.dart';
import 'commands/service/service_command.dart';
import 'commands/sessions_command.dart';
import 'commands/status_command.dart';
import 'commands/stop_command.dart';
import 'commands/tasks/tasks_command.dart';
import 'commands/token_command.dart';
import 'commands/traces/traces_command.dart';
import 'commands/workflow/workflow_command.dart';

/// Builds the runner carrying the CLI's shipped command surface.
///
/// Registration lives here rather than in `bin/dartclaw.dart` so the command
/// set a release actually exposes is reachable from a test; `main` does nothing
/// but call this and dispatch.
DartclawRunner buildDartclawRunner() => DartclawRunner()
  ..addCommand(RunnersCommand())
  ..addCommand(AuthCommand())
  ..addCommand(ConfigCommand())
  ..addCommand(GoogleAuthCommand())
  ..addCommand(InitCommand())
  ..addCommand(JobsCommand())
  ..addCommand(SetupAliasCommand())
  ..addCommand(ProjectsCommand())
  ..addCommand(ServiceCommand())
  ..addCommand(ServeCommand())
  ..addCommand(SessionsCommand())
  ..addCommand(StatusCommand())
  ..addCommand(StopCommand())
  ..addCommand(TasksCommand())
  ..addCommand(RebuildIndexCommand())
  ..addCommand(SecretsCommand())
  ..addCommand(TokenCommand())
  ..addCommand(TracesCommand())
  ..addCommand(WorkflowCommand());

/// Top-level CLI runner for DartClaw.
///
/// Carries the global options only; the shipped command set comes from
/// [buildDartclawRunner].
class DartclawRunner extends CommandRunner<void> {
  final void Function(String) _writeLine;

  new({void Function(String)? writeLine})
    : _writeLine = writeLine ?? print,
      super('dartclaw', 'DartClaw — security-conscious AI agent runtime') {
    argParser.addFlag('version', negatable: false, help: 'Print the DartClaw runtime version.');
    argParser.addOption(
      'config',
      abbr: 'c',
      help: 'Path to dartclaw.yaml config file (overrides DARTCLAW_CONFIG env var and default search)',
      valueHelp: 'path',
    );
    argParser.addOption(
      'server',
      help: 'Server address override for connected commands (for example: 3333, localhost:4000, or https://host)',
      valueHelp: 'host:port',
    );
    argParser.addOption(
      'token',
      help: 'Gateway bearer token override for connected commands, useful with remote --server targets',
      valueHelp: 'token',
    );
  }

  @override
  Future<void> runCommand(ArgResults topLevelResults) {
    if (topLevelResults.flag('version')) {
      _writeLine(dartclawVersion);
      return Future<void>.value();
    }
    return super.runCommand(topLevelResults);
  }
}
