import 'package:args/command_runner.dart';

import '../connected_command_support.dart';

class TasksReviewCommand extends ConnectedCommand {
  TasksReviewCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('action', help: 'Review action: accept, reject, or push_back')
      ..addOption('comment', help: 'Required when --action push_back')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'review';

  @override
  String get description => 'Review a task';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final taskId = requirePositionalArg('Task ID required');
    final action = (argResults!['action'] as String?)?.trim();
    final comment = (argResults!['comment'] as String?)?.trim();
    if (action == null || action.isEmpty) {
      throw UsageException('--action is required', usage);
    }
    if (action == 'push_back' && (comment == null || comment.isEmpty)) {
      throw UsageException('--comment is required when --action is push_back', usage);
    }

    final task = await apiClient.postObject(
      '/api/tasks/$taskId/review',
      body: {'action': action, if (comment != null && comment.isNotEmpty) 'comment': comment},
    );
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, task);
    } else {
      writeLine('Task ${task['id']} review applied (${task['status']}).');
    }
  });
}
