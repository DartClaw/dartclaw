import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class TracesListCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  TracesListCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser
      ..addOption('task-id')
      ..addOption('session-id')
      ..addOption('provider')
      ..addOption('since')
      ..addOption('until')
      ..addOption('limit')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List turn traces';

  @override
  Future<void> run() async {
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final payload = await apiClient.getObject(
        '/api/traces',
        queryParameters: {
          'taskId': argResults!['task-id'] as String?,
          'sessionId': argResults!['session-id'] as String?,
          'provider': argResults!['provider'] as String?,
          'since': _normalizeDateFilter(argResults!['since'] as String?),
          'until': _normalizeDateFilter(argResults!['until'] as String?),
          'limit': argResults!['limit'] as String?,
        },
      );
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, payload);
        return;
      }
      final traces = ((payload['traces'] as List?) ?? const [])
          .map((trace) => Map<String, dynamic>.from(trace as Map))
          .toList(growable: false);
      _writeLine(
        '  ${'TURN_ID'.padRight(12)}  ${'SESSION'.padRight(12)}  ${'PROVIDER'.padRight(8)}  ${'MODEL'.padRight(12)}  ${'DURATION'.padRight(10)}  ${'IN_TOKENS'.padRight(10)}  ${'OUT_TOKENS'.padRight(10)}  ${'CACHE_R'.padRight(8)}  ${'CACHE_W'.padRight(8)}  TOOLS',
      );
      for (final trace in traces) {
        _writeLine(
          '  ${truncate(trace['id']?.toString() ?? '', 12).padRight(12)}  '
          '${truncate(trace['sessionId']?.toString() ?? '', 12).padRight(12)}  '
          '${(trace['provider']?.toString() ?? '—').padRight(8)}  '
          '${truncate(trace['model']?.toString() ?? '—', 12).padRight(12)}  '
          '${_formatDuration(trace['durationMs']).padRight(10)}  '
          '${formatNumber((trace['inputTokens'] as num?)?.toInt() ?? 0).padRight(10)}  '
          '${formatNumber((trace['outputTokens'] as num?)?.toInt() ?? 0).padRight(10)}  '
          '${formatNumber((trace['cacheReadTokens'] as num?)?.toInt() ?? 0).padRight(8)}  '
          '${formatNumber((trace['cacheWriteTokens'] as num?)?.toInt() ?? 0).padRight(8)}  '
          '${((trace['toolCalls'] as List?) ?? const []).length}',
        );
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}

String? _normalizeDateFilter(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  final trimmed = raw.trim();
  final absolute = DateTime.tryParse(trimmed);
  if (absolute != null) {
    return absolute.toIso8601String();
  }
  final match = RegExp(r'^(\d+)([smhd])$').firstMatch(trimmed);
  if (match == null) {
    return trimmed;
  }
  final amount = int.parse(match.group(1)!);
  final unit = match.group(2)!;
  final duration = switch (unit) {
    's' => Duration(seconds: amount),
    'm' => Duration(minutes: amount),
    'h' => Duration(hours: amount),
    'd' => Duration(days: amount),
    _ => Duration.zero,
  };
  return DateTime.now().subtract(duration).toIso8601String();
}

String _formatDuration(Object? milliseconds) {
  final value = (milliseconds as num?)?.toInt() ?? 0;
  final duration = Duration(milliseconds: value);
  if (duration.inSeconds < 60) {
    return '${duration.inSeconds}s';
  }
  return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
}
