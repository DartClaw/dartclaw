import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class TracesShowCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  TracesShowCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a single trace';

  @override
  Future<void> run() async {
    final traceId = _requireTraceId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final trace = await apiClient.getObject('/api/traces/$traceId');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, trace);
        return;
      }
      for (final entry in trace.entries) {
        _writeLine('${entry.key}: ${entry.value}');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireTraceId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Trace ID required', usage);
    }
    return args.first;
  }
}
