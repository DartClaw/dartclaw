import 'package:args/command_runner.dart';

import 'agents_list_command.dart';
import 'agents_show_command.dart';

class AgentsCommand extends Command<void> {
  AgentsCommand() {
    addSubcommand(AgentsListCommand());
    addSubcommand(AgentsShowCommand());
  }

  @override
  String get name => 'agents';

  @override
  String get description => 'Agent pool commands';
}
