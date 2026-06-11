import '../connected_command_support.dart';

class TasksStartCommand extends ConnectedCommand {
  TasksStartCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'start';

  @override
  String get description => 'Start a task';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final taskId = requirePositionalArg('Task ID required');
    final task = await apiClient.postObject('/api/tasks/$taskId/start');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, task);
    } else {
      writeLine('Task ${task['id']} is now ${task['status']}.');
    }
  });
}
