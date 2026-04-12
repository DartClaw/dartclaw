import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ProjectsFetchCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  ProjectsFetchCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'fetch';

  @override
  String get description => 'Fetch a project from its remote';

  @override
  Future<void> run() async {
    final projectId = _requireProjectId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final project = await apiClient.postObject('/api/projects/$projectId/fetch');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, project);
      } else {
        _writeLine('Fetched project ${project['id']} (${project['status']}).');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireProjectId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Project ID required', usage);
    }
    return args.first;
  }
}
