import 'package:args/command_runner.dart';

import 'traces_list_command.dart';
import 'traces_show_command.dart';

class TracesCommand extends Command<void> {
  new() {
    addSubcommand(TracesListCommand());
    addSubcommand(TracesShowCommand());
  }

  @override
  String get name => 'traces';

  @override
  String get description => 'Turn trace commands';
}
