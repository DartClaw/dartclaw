import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class TasksShowCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  TasksShowCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a task';

  @override
  Future<void> run() async {
    final taskId = _requireTaskId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final task = await apiClient.getObject('/api/tasks/$taskId');
      final execution = task['agentExecution'] is Map<String, dynamic>
          ? task['agentExecution'] as Map<String, dynamic>
          : const <String, dynamic>{};
      final workflowStep = task['workflowStepExecution'] is Map<String, dynamic>
          ? task['workflowStepExecution'] as Map<String, dynamic>
          : const <String, dynamic>{};
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, task);
        return;
      }
      _writeLine('Task:         ${task['id']}');
      _writeLine('  Title:      ${task['title']}');
      _writeLine('  Description:${task['description']}');
      _writeLine('  Type:       ${task['type']}');
      _writeLine('  Status:     ${task['status']}');
      _writeLine('  Project:    ${task['projectId'] ?? '—'}');
      _writeLine('  Provider:   ${execution['provider'] ?? '—'}');
      _writeLine('  Model:      ${execution['model'] ?? '—'}');
      _writeLine('  Session:    ${execution['sessionId'] ?? '—'}');
      _writeLine('  Budget:     ${execution['budgetTokens'] ?? '—'}');
      if (workflowStep.isNotEmpty) {
        _writeLine('  Workflow:   ${workflowStep['workflowRunId'] ?? '—'}');
        _writeLine('  Step:       ${workflowStep['stepId'] ?? '—'} (#${workflowStep['stepIndex'] ?? '—'})');
      }
      _writeLine('  Created:    ${formatDateTime(task['createdAt'])}');
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireTaskId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Task ID required', usage);
    }
    return args.first;
  }
}
