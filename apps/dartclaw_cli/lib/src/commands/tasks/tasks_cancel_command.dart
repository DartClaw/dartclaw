import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class TasksCancelCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  TasksCancelCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'cancel';

  @override
  String get description => 'Cancel a task';

  @override
  Future<void> run() async {
    final taskId = _requireTaskId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final task = await apiClient.postObject('/api/tasks/$taskId/cancel');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, task);
      } else {
        _writeLine('Task ${task['id']} is now ${task['status']}.');
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
