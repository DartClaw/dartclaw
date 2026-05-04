import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class SessionsArchiveCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  SessionsArchiveCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'archive';

  @override
  String get description => 'Archive a session';

  @override
  Future<void> run() async {
    final sessionId = _requireSessionId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final session = await apiClient.postObject('/api/sessions/$sessionId/archive');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, session);
      } else {
        _writeLine('Archived session ${session['id']} (${session['type']}).');
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
