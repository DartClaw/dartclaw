import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class TasksListCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  TasksListCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
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
  Future<void> run() async {
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final tasks = await apiClient.getList(
        '/api/tasks',
        queryParameters: {'status': argResults!['status'] as String?, 'type': argResults!['type'] as String?},
      );
      final limit = int.tryParse((argResults!['limit'] as String?) ?? '');
      final visible = limit == null || limit >= tasks.length ? tasks : tasks.take(limit).toList(growable: false);
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, visible);
        return;
      }
      if (visible.isEmpty) {
        _writeLine('No tasks found.');
        return;
      }
      _writeLine(
        '  ${'ID'.padRight(8)}  ${'TITLE'.padRight(28)}  ${'TYPE'.padRight(12)}  ${'STATUS'.padRight(16)}  PROJECT',
      );
      for (final raw in visible) {
        final task = Map<String, dynamic>.from(raw as Map);
        final id = truncate(task['id']?.toString() ?? '', 8).padRight(8);
        final title = truncate(task['title']?.toString() ?? '', 28).padRight(28);
        final type = (task['type']?.toString() ?? '').padRight(12);
        final status = (task['status']?.toString() ?? '').padRight(16);
        final project = task['projectId']?.toString() ?? '—';
        _writeLine('  $id  $title  $type  $status  $project');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
