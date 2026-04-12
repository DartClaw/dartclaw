import 'package:args/command_runner.dart';

import 'cleanup_command.dart';
import 'sessions/sessions_archive_command.dart';
import 'sessions/sessions_delete_command.dart';
import 'sessions/sessions_list_command.dart';
import 'sessions/sessions_messages_command.dart';
import 'sessions/sessions_show_command.dart';

/// Parent command for session management: `dartclaw sessions <subcommand>`.
class SessionsCommand extends Command<void> {
  SessionsCommand() {
    addSubcommand(SessionsListCommand());
    addSubcommand(SessionsShowCommand());
    addSubcommand(SessionsMessagesCommand());
    addSubcommand(SessionsDeleteCommand());
    addSubcommand(SessionsArchiveCommand());
    addSubcommand(CleanupCommand());
  }

  @override
  String get name => 'sessions';

  @override
  String get description => 'Session management commands';
}
