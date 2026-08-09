import '../connected_command_support.dart';

class RunnersListCommand extends ConnectedCommand {
  RunnersListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List execution runners';

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
      '  ${'ID'.padRight(4)}  ${'ROLE'.padRight(8)}  ${'PROVIDER'.padRight(10)}  '
      '${'STATUS'.padRight(10)}  ${'TURNS'.padRight(8)}  TOKENS',
    );
    for (final runner in runners) {
      final role = (runner['role']?.toString() ?? '—').padRight(8);
      final provider = (runner['providerId']?.toString() ?? '—').padRight(10);
      final status = (runner['state']?.toString() ?? '—').padRight(10);
      final turns = formatNumber((runner['turnsCompleted'] as num?)?.toInt() ?? 0).padRight(8);
      final tokens = formatNumber((runner['tokensConsumed'] as num?)?.toInt() ?? 0);
      writeLine('  ${(runner['runnerId']?.toString() ?? '').padRight(4)}  $role  $provider  $status  $turns  $tokens');
    }
    final capacity = Map<String, dynamic>.from(payload['capacity'] as Map);
    writeLine('');
    writeLine('Observed runners: ${capacity['runnerCount']}');
    writeLine('Primary lane: ${capacity['primaryActive'] == true ? 'active' : 'idle'}');
    writeLine(
      'Worker capacity: ${capacity['configured']} configured, ${capacity['effective']} effective, '
      '${capacity['active']} active, ${capacity['available']} available, ${capacity['queued']} queued, '
      '${capacity['cached']} cached, ${capacity['quarantined']} quarantined',
    );
  });
}
