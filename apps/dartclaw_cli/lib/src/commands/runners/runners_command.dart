import 'package:args/command_runner.dart';

import 'runners_list_command.dart';
import 'runners_show_command.dart';

class RunnersCommand extends Command<void> {
  new() {
    addSubcommand(RunnersListCommand());
    addSubcommand(RunnersShowCommand());
  }

  @override
  String get name => 'runners';

  @override
  String get description => 'Harness runner commands';
}
