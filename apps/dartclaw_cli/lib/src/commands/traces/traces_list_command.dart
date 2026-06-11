import 'package:dartclaw_core/dartclaw_core.dart' show humanizeDurationMs;

import '../connected_command_support.dart';

class TracesListCommand extends ConnectedCommand {
  TracesListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
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
  Future<void> run() => runConnected((apiClient) async {
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
      writePrettyJson(writeLine, payload);
      return;
    }
    final traces = ((payload['traces'] as List?) ?? const [])
        .map((trace) => Map<String, dynamic>.from(trace as Map))
        .toList(growable: false);
    writeLine(
      '  ${'TURN_ID'.padRight(12)}  ${'SESSION'.padRight(12)}  ${'PROVIDER'.padRight(8)}  ${'MODEL'.padRight(12)}  ${'DURATION'.padRight(10)}  ${'IN_TOKENS'.padRight(10)}  ${'OUT_TOKENS'.padRight(10)}  ${'CACHE_R'.padRight(8)}  ${'CACHE_W'.padRight(8)}  TOOLS',
    );
    for (final trace in traces) {
      writeLine(
        '  ${truncate(trace['id']?.toString() ?? '', 12).padRight(12)}  '
        '${truncate(trace['sessionId']?.toString() ?? '', 12).padRight(12)}  '
        '${(trace['provider']?.toString() ?? '—').padRight(8)}  '
        '${truncate(trace['model']?.toString() ?? '—', 12).padRight(12)}  '
        '${humanizeDurationMs(trace['durationMs'] as num?, dropZeroRemainder: false).padRight(10)}  '
        '${formatNumber((trace['inputTokens'] as num?)?.toInt() ?? 0).padRight(10)}  '
        '${formatNumber((trace['outputTokens'] as num?)?.toInt() ?? 0).padRight(10)}  '
        '${formatNumber((trace['cacheReadTokens'] as num?)?.toInt() ?? 0).padRight(8)}  '
        '${formatNumber((trace['cacheWriteTokens'] as num?)?.toInt() ?? 0).padRight(8)}  '
        '${((trace['toolCalls'] as List?) ?? const []).length}',
      );
    }
  });
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
