import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ProjectsRemoveCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;
  final bool Function() _hasTerminal;
  final String? Function() _readLine;

  ProjectsRemoveCommand({
    DartclawConfig? config,
    DartclawApiClient? apiClient,
    WriteLine? writeLine,
    ExitFn? exitFn,
    bool Function()? hasTerminal,
    String? Function()? readLine,
  }) : _config = config,
       _apiClient = apiClient,
       _writeLine = writeLine ?? stdout.writeln,
       _exitFn = exitFn ?? exit,
       _hasTerminal = hasTerminal ?? (() => stdin.hasTerminal),
       _readLine = readLine ?? stdin.readLineSync {
    argParser
      ..addFlag('yes', negatable: false, help: 'Skip the confirmation prompt')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'remove';

  @override
  String get description => 'Remove a project';

  @override
  Future<void> run() async {
    final projectId = _requireProjectId();
    if (!_shouldProceed(projectId)) {
      _writeLine('Project removal aborted.');
      _exitFn(1);
    }

    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final result = await apiClient.deleteObject('/api/projects/$projectId');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, result);
      } else {
        _writeLine('Removed project $projectId.');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  bool _shouldProceed(String projectId) {
    if (argResults!['yes'] as bool || !_hasTerminal()) {
      return true;
    }
    _writeLine('Remove project $projectId? This also removes related tasks, worktrees, and runtime state. [y/N]');
    final answer = _readLine()?.trim().toLowerCase();
    return answer == 'y' || answer == 'yes';
  }

  String _requireProjectId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Project ID required', usage);
    }
    return args.first;
  }
}
