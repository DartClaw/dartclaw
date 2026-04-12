import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ProjectsListCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  ProjectsListCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List projects';

  @override
  Future<void> run() async {
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final projects = await apiClient.getList('/api/projects');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, projects);
        return;
      }
      if (projects.isEmpty) {
        _writeLine('No projects found.');
        return;
      }
      _writeLine(
        '  ${'ID'.padRight(16)}  ${'NAME'.padRight(18)}  ${'REMOTE'.padRight(28)}  ${'BRANCH'.padRight(12)}  STATUS',
      );
      for (final raw in projects) {
        final project = Map<String, dynamic>.from(raw as Map);
        final id = truncate(project['id']?.toString() ?? '', 16).padRight(16);
        final name = truncate(project['name']?.toString() ?? '', 18).padRight(18);
        final remote = truncate(project['remoteUrl']?.toString() ?? '', 28).padRight(28);
        final branch = (project['defaultBranch']?.toString() ?? '').padRight(12);
        final status = project['status']?.toString() ?? 'unknown';
        _writeLine('  $id  $name  $remote  $branch  $status');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
