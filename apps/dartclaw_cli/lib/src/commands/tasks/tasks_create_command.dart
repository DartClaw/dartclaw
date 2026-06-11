import 'package:args/command_runner.dart';

import '../connected_command_support.dart';

class TasksCreateCommand extends ConnectedCommand {
  TasksCreateCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('title', help: 'Task title')
      ..addOption('description', help: 'Task description')
      ..addOption('type', help: 'Task type')
      ..addOption('project', help: 'Project ID')
      ..addOption('provider', help: 'Provider override')
      ..addFlag('auto-start', negatable: false, help: 'Start the task immediately after creation')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'create';

  @override
  String get description => 'Create a task';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final title = (argResults!['title'] as String?)?.trim();
    final description = (argResults!['description'] as String?)?.trim();
    final type = (argResults!['type'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      throw UsageException('--title is required', usage);
    }
    if (description == null || description.isEmpty) {
      throw UsageException('--description is required', usage);
    }
    if (type == null || type.isEmpty) {
      throw UsageException('--type is required', usage);
    }

    final created = await apiClient.postObject(
      '/api/tasks',
      body: {
        'title': title,
        'description': description,
        'type': type,
        if ((argResults!['project'] as String?)?.trim().isNotEmpty == true)
          'projectId': (argResults!['project'] as String).trim(),
        if ((argResults!['provider'] as String?)?.trim().isNotEmpty == true)
          'provider': (argResults!['provider'] as String).trim(),
        'autoStart': argResults!['auto-start'] as bool,
      },
    );
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, created);
    } else {
      writeLine('Created task ${created['id']} (${created['status']}).');
    }
  });
}
