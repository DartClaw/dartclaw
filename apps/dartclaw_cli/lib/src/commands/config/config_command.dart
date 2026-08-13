import 'package:args/command_runner.dart';

import 'config_get_command.dart';
import 'config_set_command.dart';
import 'config_show_command.dart';

class ConfigCommand extends Command<void> {
  new() {
    addSubcommand(ConfigShowCommand());
    addSubcommand(ConfigGetCommand());
    addSubcommand(ConfigSetCommand());
  }

  @override
  String get name => 'config';

  @override
  String get description => 'Configuration commands';
}
