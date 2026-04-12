import 'package:args/command_runner.dart';

import 'projects_add_command.dart';
import 'projects_fetch_command.dart';
import 'projects_list_command.dart';
import 'projects_remove_command.dart';
import 'projects_show_command.dart';

class ProjectsCommand extends Command<void> {
  ProjectsCommand() {
    addSubcommand(ProjectsListCommand());
    addSubcommand(ProjectsAddCommand());
    addSubcommand(ProjectsShowCommand());
    addSubcommand(ProjectsFetchCommand());
    addSubcommand(ProjectsRemoveCommand());
  }

  @override
  String get name => 'projects';

  @override
  String get description => 'Project management commands';
}
