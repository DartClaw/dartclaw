import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class SessionsDeleteCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  SessionsDeleteCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a session';

  @override
  Future<void> run() async {
    final sessionId = _requireSessionId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final result = await apiClient.delete('/api/sessions/$sessionId');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, result);
      } else {
        _writeLine('Deleted session $sessionId.');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireSessionId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Session ID required', usage);
    }
    return args.first;
  }
}
