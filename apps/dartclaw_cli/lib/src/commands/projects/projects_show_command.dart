import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ProjectsShowCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  ProjectsShowCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a project';

  @override
  Future<void> run() async {
    final projectId = _requireProjectId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final project = await apiClient.getObject('/api/projects/$projectId');
      final status = await apiClient.getObject('/api/projects/$projectId/status');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, {'project': project, 'status': status});
        return;
      }
      _writeLine('Project:      ${project['id']}');
      _writeLine('  Name:       ${project['name']}');
      _writeLine('  Remote:     ${project['remoteUrl']}');
      _writeLine('  Branch:     ${project['defaultBranch']}');
      _writeLine('  Status:     ${status['status']}');
      _writeLine('  Clone:      ${status['cloneExists'] == true ? 'present' : 'missing'}');
      _writeLine('  Last fetch: ${formatDateTime(status['lastFetchAt'])}');
      if (status['errorMessage'] != null) {
        _writeLine('  Error:      ${status['errorMessage']}');
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
