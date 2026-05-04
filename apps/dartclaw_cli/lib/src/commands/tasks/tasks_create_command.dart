import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class TasksCreateCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  TasksCreateCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
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
  Future<void> run() async {
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

    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
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
        writePrettyJson(_writeLine, created);
      } else {
        _writeLine('Created task ${created['id']} (${created['status']}).');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
