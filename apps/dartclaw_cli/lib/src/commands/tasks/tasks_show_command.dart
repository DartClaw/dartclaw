import '../connected_command_support.dart';

class TasksShowCommand extends ConnectedCommand {
  TasksShowCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a task';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final taskId = requirePositionalArg('Task ID required');
    final task = await apiClient.getObject('/api/tasks/$taskId');
    final execution = task['agentExecution'] is Map<String, dynamic>
        ? task['agentExecution'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final workflowStep = task['workflowStepExecution'] is Map<String, dynamic>
        ? task['workflowStepExecution'] as Map<String, dynamic>
        : const <String, dynamic>{};
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, task);
      return;
    }
    writeLine('Task:         ${task['id']}');
    writeLine('  Title:      ${task['title']}');
    writeLine('  Description:${task['description']}');
    writeLine('  Type:       ${task['type']}');
    writeLine('  Status:     ${task['status']}');
    writeLine('  Project:    ${task['projectId'] ?? '—'}');
    writeLine('  Provider:   ${execution['provider'] ?? '—'}');
    writeLine('  Model:      ${execution['model'] ?? '—'}');
    writeLine('  Session:    ${execution['sessionId'] ?? '—'}');
    writeLine('  Budget:     ${execution['budgetTokens'] ?? '—'}');
    if (workflowStep.isNotEmpty) {
      writeLine('  Workflow:   ${workflowStep['workflowRunId'] ?? '—'}');
      writeLine('  Step:       ${workflowStep['stepId'] ?? '—'} (#${workflowStep['stepIndex'] ?? '—'})');
    }
    writeLine('  Created:    ${formatDateTime(task['createdAt'])}');
  });
}
