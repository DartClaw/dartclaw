import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class WorkflowResumeCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  WorkflowResumeCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'resume';

  @override
  String get description => 'Resume a paused workflow';

  @override
  String get invocation => '${runner!.executableName} workflow resume <runId>';

  @override
  Future<void> run() async {
    final runId = _requireRunId();
    final apiClient = _resolveApiClient();
    try {
      final result = await apiClient.postObject('/api/workflows/runs/$runId/resume');
      if (argResults!['json'] as bool) {
        _writeLine(const JsonEncoder.withIndent('  ').convert(result));
      } else {
        _writeLine('Workflow ${result['id']} resumed (${result['status']}).');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireRunId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Run ID required', usage);
    }
    return args.first;
  }

  DartclawApiClient _resolveApiClient() {
    if (_apiClient != null) {
      return _apiClient;
    }
    final config = _config ?? loadCliConfig(configPath: _globalOptionString(globalResults, 'config'));
    return DartclawApiClient.fromConfig(config: config, serverOverride: _serverOverride(globalResults));
  }
}

String? _serverOverride(ArgResults? results) {
  return _globalOptionString(results, 'server');
}

String? _globalOptionString(ArgResults? results, String name) {
  if (results == null) return null;
  try {
    return results[name] as String?;
  } on ArgumentError {
    return null;
  }
}
