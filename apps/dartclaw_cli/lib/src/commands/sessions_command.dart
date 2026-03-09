import 'package:args/command_runner.dart';

import 'cleanup_command.dart';

/// Parent command for session management: `dartclaw sessions <subcommand>`.
class SessionsCommand extends Command<void> {
  SessionsCommand() {
    addSubcommand(CleanupCommand());
  }

  @override
  String get name => 'sessions';

  @override
  String get description => 'Session management commands';
}
