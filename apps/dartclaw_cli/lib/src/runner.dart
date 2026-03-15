import 'package:args/command_runner.dart';

/// Top-level CLI runner for DartClaw.
///
/// Subcommands (serve, status, etc.) are registered via [addCommand]
/// after construction — see `main()` in `bin/dartclaw.dart`.
class DartclawRunner extends CommandRunner<void> {
  DartclawRunner() : super('dartclaw', 'DartClaw — security-focused agent runtime') {
    argParser.addOption(
      'config',
      abbr: 'c',
      help: 'Path to dartclaw.yaml config file (overrides DARTCLAW_CONFIG env var and default search)',
      valueHelp: 'path',
    );
  }
}
