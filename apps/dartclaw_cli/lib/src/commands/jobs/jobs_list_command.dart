import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class JobsListCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  JobsListCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List scheduled jobs';

  @override
  Future<void> run() async {
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final jobs = await apiClient.getList('/api/scheduling/jobs');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, jobs);
        return;
      }
      if (jobs.isEmpty) {
        _writeLine('No scheduled jobs found.');
        return;
      }
      _writeLine('  ${'NAME'.padRight(20)}  ${'SCHEDULE'.padRight(16)}  TYPE');
      for (final raw in jobs) {
        final job = Map<String, dynamic>.from(raw as Map);
        _writeLine(
          '  ${truncate(job['name']?.toString() ?? '', 20).padRight(20)}  '
          '${truncate(job['schedule']?.toString() ?? '', 16).padRight(16)}  '
          '${job['type']}',
        );
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
