import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class AgentsListCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  AgentsListCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List pool runners';

  @override
  Future<void> run() async {
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final payload = await apiClient.getObject('/api/agents');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, payload);
        return;
      }
      final runners = ((payload['runners'] as List?) ?? const [])
          .map((runner) => Map<String, dynamic>.from(runner as Map))
          .toList(growable: false);
      _writeLine(
        '  ${'ID'.padRight(4)}  ${'PROVIDER'.padRight(10)}  ${'STATUS'.padRight(10)}  ${'TURNS'.padRight(8)}  TOKENS',
      );
      for (final runner in runners) {
        final provider = (runner['provider']?.toString() ?? '—').padRight(10);
        final status = (runner['status']?.toString() ?? '—').padRight(10);
        final turns = formatNumber((runner['turnCount'] as num?)?.toInt() ?? 0).padRight(8);
        final tokens = formatNumber((runner['totalTokens'] as num?)?.toInt() ?? 0);
        _writeLine('  ${(runner['id']?.toString() ?? '').padRight(4)}  $provider  $status  $turns  $tokens');
      }
      final pool = Map<String, dynamic>.from(payload['pool'] as Map);
      _writeLine('');
      _writeLine('Pool: ${pool['size']} runners, ${pool['activeCount']} active, ${pool['availableCount']} available');
      if (pool['maxConcurrentTasks'] != null) {
        _writeLine('Max concurrent tasks: ${pool['maxConcurrentTasks']}');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
