import 'package:args/command_runner.dart';

import 'tasks_cancel_command.dart';
import 'tasks_create_command.dart';
import 'tasks_list_command.dart';
import 'tasks_review_command.dart';
import 'tasks_show_command.dart';
import 'tasks_start_command.dart';

class TasksCommand extends Command<void> {
  TasksCommand() {
    addSubcommand(TasksListCommand());
    addSubcommand(TasksShowCommand());
    addSubcommand(TasksCreateCommand());
    addSubcommand(TasksStartCommand());
    addSubcommand(TasksCancelCommand());
    addSubcommand(TasksReviewCommand());
  }

  @override
  String get name => 'tasks';

  @override
  String get description => 'Task management commands';
}
