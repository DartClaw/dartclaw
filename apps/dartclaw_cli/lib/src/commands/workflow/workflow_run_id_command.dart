import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../cli_global_options.dart';
import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

/// Base for workflow CLI subcommands that target a single run by positional id
/// and POST to a `/api/workflows/runs/<runId>/<verb>` endpoint.
///
/// Concrete subcommands provide [name], [description], and call [runAgainstRun]
/// from [run] with the path suffix and verb that matches their REST endpoint.
abstract class WorkflowRunIdCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  WorkflowRunIdCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get invocation => '${runner!.executableName} workflow $name <runId>';

  /// POSTs to `/api/workflows/runs/<runId>/<pathSuffix>` and prints either the
  /// JSON envelope or `Workflow <id> <verb> (<status>).`.
  Future<void> runAgainstRun({required String pathSuffix, required String verb}) async {
    final runId = _requireRunId();
    final apiClient = _resolveApiClient();
    try {
      final result = await apiClient.postObject('/api/workflows/runs/$runId/$pathSuffix');
      if (argResults!['json'] as bool) {
        _writeLine(const JsonEncoder.withIndent('  ').convert(result));
      } else {
        _writeLine('Workflow ${result['id']} $verb (${result['status']}).');
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
    final config = _config ?? loadCliConfig(configPath: globalOptionString(globalResults, 'config'));
    return DartclawApiClient.fromConfig(
      config: config,
      serverOverride: serverOverride(globalResults),
      tokenOverride: globalOptionString(globalResults, 'token'),
    );
  }
}
