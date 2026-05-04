import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class AgentsShowCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  AgentsShowCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a single runner';

  @override
  Future<void> run() async {
    final runnerId = _requireRunnerId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final runner = await apiClient.getObject('/api/agents/$runnerId');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, runner);
        return;
      }
      for (final entry in runner.entries) {
        _writeLine('${entry.key}: ${entry.value}');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireRunnerId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Runner ID required', usage);
    }
    return args.first;
  }
}
