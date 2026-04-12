import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show CronExpression;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class JobsCreateCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  JobsCreateCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser
      ..addOption('name', help: 'Job name')
      ..addOption('schedule', help: 'Cron schedule expression')
      ..addOption('type', help: 'prompt or task', defaultsTo: 'prompt')
      ..addOption('prompt', help: 'Prompt body for prompt-type jobs')
      ..addOption('delivery', help: 'announce, webhook, or none', defaultsTo: 'announce')
      ..addOption('title', help: 'Task title for task-type jobs')
      ..addOption('description', help: 'Task description for task-type jobs')
      ..addOption('task-type', help: 'Task type for task-type jobs')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'create';

  @override
  String get description => 'Create a scheduled job';

  @override
  Future<void> run() async {
    final name = (argResults!['name'] as String?)?.trim();
    final schedule = (argResults!['schedule'] as String?)?.trim();
    final type = (argResults!['type'] as String?)?.trim() ?? 'prompt';
    if (name == null || name.isEmpty) {
      throw UsageException('--name is required', usage);
    }
    if (schedule == null || schedule.isEmpty) {
      throw UsageException('--schedule is required', usage);
    }
    try {
      CronExpression.parse(schedule);
    } catch (error) {
      throw UsageException('Invalid cron expression: $schedule', usage);
    }

    final body = <String, Object?>{'name': name, 'schedule': schedule, 'type': type};
    if (type == 'prompt') {
      final prompt = (argResults!['prompt'] as String?)?.trim();
      if (prompt == null || prompt.isEmpty) {
        throw UsageException('--prompt is required when --type=prompt', usage);
      }
      body['prompt'] = prompt;
      body['delivery'] = (argResults!['delivery'] as String?)?.trim() ?? 'announce';
    } else if (type == 'task') {
      final title = (argResults!['title'] as String?)?.trim();
      final description = (argResults!['description'] as String?)?.trim();
      final taskType = (argResults!['task-type'] as String?)?.trim();
      if (title == null ||
          title.isEmpty ||
          description == null ||
          description.isEmpty ||
          taskType == null ||
          taskType.isEmpty) {
        throw UsageException('--title, --description, and --task-type are required when --type=task', usage);
      }
      body['task'] = {'title': title, 'description': description, 'task_type': taskType};
    } else {
      throw UsageException('--type must be prompt or task', usage);
    }

    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final job = await apiClient.postObject('/api/scheduling/jobs', body: body);
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, job);
      } else {
        _writeLine('Created job $name. Restart the server to load scheduling changes.');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
