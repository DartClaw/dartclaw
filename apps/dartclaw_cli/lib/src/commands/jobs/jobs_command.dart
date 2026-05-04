import 'package:args/command_runner.dart';

import 'jobs_create_command.dart';
import 'jobs_delete_command.dart';
import 'jobs_list_command.dart';
import 'jobs_show_command.dart';

class JobsCommand extends Command<void> {
  JobsCommand() {
    addSubcommand(JobsListCommand());
    addSubcommand(JobsCreateCommand());
    addSubcommand(JobsShowCommand());
    addSubcommand(JobsDeleteCommand());
  }

  @override
  String get name => 'jobs';

  @override
  String get description => 'Scheduled job commands';
}
