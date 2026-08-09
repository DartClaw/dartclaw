import '../connected_command_support.dart';

class RunnersListCommand extends ConnectedCommand {
  RunnersListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List pool runners';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final payload = await apiClient.getObject('/api/runners');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, payload);
      return;
    }
    final runners = ((payload['runners'] as List?) ?? const [])
        .map((runner) => Map<String, dynamic>.from(runner as Map))
        .toList(growable: false);
    writeLine(
      '  ${'ID'.padRight(4)}  ${'PROVIDER'.padRight(10)}  ${'STATUS'.padRight(10)}  ${'TURNS'.padRight(8)}  TOKENS',
    );
    for (final runner in runners) {
      final provider = (runner['providerId']?.toString() ?? '—').padRight(10);
      final status = (runner['state']?.toString() ?? '—').padRight(10);
      final turns = formatNumber((runner['turnsCompleted'] as num?)?.toInt() ?? 0).padRight(8);
      final tokens = formatNumber((runner['tokensConsumed'] as num?)?.toInt() ?? 0);
      writeLine('  ${(runner['runnerId']?.toString() ?? '').padRight(4)}  $provider  $status  $turns  $tokens');
    }
    final pool = Map<String, dynamic>.from(payload['pool'] as Map);
    writeLine('');
    writeLine('Pool: ${pool['size']} runners, ${pool['activeCount']} active, ${pool['availableCount']} available');
    if (pool['maxConcurrentWorkers'] != null) {
      writeLine('Max concurrent workers: ${pool['maxConcurrentWorkers']}');
    }
  });
}
