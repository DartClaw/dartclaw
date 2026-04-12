import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class TasksReviewCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  TasksReviewCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
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
  Future<void> run() async {
    final taskId = _requireTaskId();
    final action = (argResults!['action'] as String?)?.trim();
    final comment = (argResults!['comment'] as String?)?.trim();
    if (action == null || action.isEmpty) {
      throw UsageException('--action is required', usage);
    }
    if (action == 'push_back' && (comment == null || comment.isEmpty)) {
      throw UsageException('--comment is required when --action is push_back', usage);
    }

    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final task = await apiClient.postObject(
        '/api/tasks/$taskId/review',
        body: {'action': action, if (comment != null && comment.isNotEmpty) 'comment': comment},
      );
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, task);
      } else {
        _writeLine('Task ${task['id']} review applied (${task['status']}).');
      }
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
