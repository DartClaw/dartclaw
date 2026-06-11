import '../connected_command_support.dart';

class TasksListCommand extends ConnectedCommand {
  TasksListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('status', help: 'Filter by task status')
      ..addOption('type', help: 'Filter by task type')
      ..addOption('limit', help: 'Maximum number of tasks to show')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List tasks';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final tasks = await apiClient.getList(
      '/api/tasks',
      queryParameters: {'status': argResults!['status'] as String?, 'type': argResults!['type'] as String?},
    );
    final limit = int.tryParse((argResults!['limit'] as String?) ?? '');
    final visible = limit == null || limit >= tasks.length ? tasks : tasks.take(limit).toList(growable: false);
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, visible);
      return;
    }
    if (visible.isEmpty) {
      writeLine('No tasks found.');
      return;
    }
    writeLine(
      '  ${'ID'.padRight(8)}  ${'TITLE'.padRight(28)}  ${'STATUS'.padRight(16)}  ${'EXECUTION'.padRight(24)}  PROJECT',
    );
    for (final raw in visible) {
      final task = Map<String, dynamic>.from(raw as Map);
      final execution = task['agentExecution'] is Map
          ? Map<String, dynamic>.from(task['agentExecution'] as Map)
          : const <String, dynamic>{};
      final workflowStep = task['workflowStepExecution'] is Map
          ? Map<String, dynamic>.from(task['workflowStepExecution'] as Map)
          : const <String, dynamic>{};
      final id = truncate(task['id']?.toString() ?? '', 8).padRight(8);
      final title = truncate(task['title']?.toString() ?? '', 28).padRight(28);
      final status = (task['status']?.toString() ?? '').padRight(16);
      final provider = execution['provider']?.toString();
      final model = execution['model']?.toString();
      final stepId = workflowStep['stepId']?.toString();
      final executionSummary = truncate(
        [
          if (provider != null && provider.isNotEmpty) provider,
          if (model != null && model.isNotEmpty) model,
          if (stepId != null && stepId.isNotEmpty) 'step:$stepId',
        ].join(' · '),
        24,
      ).padRight(24);
      final project = task['projectId']?.toString() ?? '—';
      writeLine('  $id  $title  $status  $executionSummary  $project');
    }
  });
}
