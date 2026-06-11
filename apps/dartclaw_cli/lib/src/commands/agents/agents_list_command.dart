import '../connected_command_support.dart';

class AgentsListCommand extends ConnectedCommand {
  AgentsListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List pool runners';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final payload = await apiClient.getObject('/api/agents');
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
      final provider = (runner['provider']?.toString() ?? '—').padRight(10);
      final status = (runner['status']?.toString() ?? '—').padRight(10);
      final turns = formatNumber((runner['turnCount'] as num?)?.toInt() ?? 0).padRight(8);
      final tokens = formatNumber((runner['totalTokens'] as num?)?.toInt() ?? 0);
      writeLine('  ${(runner['id']?.toString() ?? '').padRight(4)}  $provider  $status  $turns  $tokens');
    }
    final pool = Map<String, dynamic>.from(payload['pool'] as Map);
    writeLine('');
    writeLine('Pool: ${pool['size']} runners, ${pool['activeCount']} active, ${pool['availableCount']} available');
    if (pool['maxConcurrentTasks'] != null) {
      writeLine('Max concurrent tasks: ${pool['maxConcurrentTasks']}');
    }
  });
}
