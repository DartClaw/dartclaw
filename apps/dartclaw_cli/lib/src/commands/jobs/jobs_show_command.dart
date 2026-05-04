import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class JobsShowCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  JobsShowCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a scheduled job';

  @override
  Future<void> run() async {
    final jobName = _requireJobName();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final job = await apiClient.getObject('/api/scheduling/jobs/$jobName');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, job);
        return;
      }
      for (final entry in job.entries) {
        _writeLine('${entry.key}: ${entry.value}');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireJobName() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Job name required', usage);
    }
    return args.first;
  }
}
