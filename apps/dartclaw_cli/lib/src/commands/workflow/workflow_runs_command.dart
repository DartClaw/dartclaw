import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class WorkflowRunsCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  WorkflowRunsCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser
      ..addOption('status', help: 'Filter by workflow status')
      ..addOption('definition', help: 'Filter by workflow definition name')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'runs';

  @override
  String get description => 'List recent workflow runs from the server';

  @override
  Future<void> run() async {
    final apiClient = _resolveApiClient();
    try {
      final runs = await apiClient.getList(
        '/api/workflows/runs',
        queryParameters: {
          'status': argResults!['status'] as String?,
          'definition': argResults!['definition'] as String?,
        },
      );
      if (argResults!['json'] as bool) {
        _writeLine(const JsonEncoder.withIndent('  ').convert(runs));
        return;
      }
      _printTable(runs);
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  DartclawApiClient _resolveApiClient() {
    if (_apiClient != null) {
      return _apiClient;
    }
    final config = _config ?? loadCliConfig(configPath: _globalOptionString(globalResults, 'config'));
    return DartclawApiClient.fromConfig(config: config, serverOverride: _serverOverride(globalResults));
  }

  void _printTable(List<dynamic> runs) {
    if (runs.isEmpty) {
      _writeLine('No workflow runs found.');
      return;
    }
    _writeLine('  ${'ID'.padRight(12)}  ${'DEFINITION'.padRight(24)}  ${'STATUS'.padRight(10)}  STARTED');
    for (final raw in runs) {
      final run = Map<String, dynamic>.from(raw as Map);
      final id = _truncate(run['id']?.toString() ?? '', 12).padRight(12);
      final definition = _truncate(run['definitionName']?.toString() ?? '', 24).padRight(24);
      final status = (run['status']?.toString() ?? '').padRight(10);
      final started = _formatDateTime(run['startedAt']?.toString());
      _writeLine('  $id  $definition  $status  $started');
    }
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

String _truncate(String value, int width) {
  if (value.length <= width) {
    return value;
  }
  return '${value.substring(0, width - 3)}...';
}

String _formatDateTime(String? value) {
  if (value == null || value.isEmpty) {
    return '—';
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value;
  }
  return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
      '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
}
