import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ProjectsAddCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  ProjectsAddCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser
      ..addOption('name', help: 'Project name')
      ..addOption('remote-url', help: 'Remote Git URL')
      ..addOption('branch', help: 'Default branch', defaultsTo: 'main')
      ..addOption('credentials-ref', help: 'Optional credentials reference')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Add a project';

  @override
  Future<void> run() async {
    final name = (argResults!['name'] as String?)?.trim();
    final remoteUrl = (argResults!['remote-url'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      throw UsageException('--name is required', usage);
    }
    if (remoteUrl == null || remoteUrl.isEmpty) {
      throw UsageException('--remote-url is required', usage);
    }

    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final project = await apiClient.postObject(
        '/api/projects',
        body: {
          'name': name,
          'remoteUrl': remoteUrl,
          'defaultBranch': (argResults!['branch'] as String?)?.trim() ?? 'main',
          if ((argResults!['credentials-ref'] as String?)?.trim().isNotEmpty == true)
            'credentialsRef': (argResults!['credentials-ref'] as String).trim(),
        },
      );
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, project);
      } else {
        _writeLine('Added project ${project['id']} (${project['status']}).');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
