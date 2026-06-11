import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show dartclawVersion;

/// Top-level CLI runner for DartClaw.
///
/// Subcommands (serve, status, etc.) are registered via [addCommand]
/// after construction — see `main()` in `bin/dartclaw.dart`.
class DartclawRunner extends CommandRunner<void> {
  final void Function(String) _writeLine;

  DartclawRunner({void Function(String)? writeLine})
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
