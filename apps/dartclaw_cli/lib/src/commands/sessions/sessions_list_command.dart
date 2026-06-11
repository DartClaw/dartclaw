import '../connected_command_support.dart';

class SessionsListCommand extends ConnectedCommand {
  SessionsListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('type', help: 'Filter by session type')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List sessions';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final sessions = await apiClient.getList(
      '/api/sessions',
      queryParameters: {'type': argResults!['type'] as String?},
    );
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, sessions);
      return;
    }
    if (sessions.isEmpty) {
      writeLine('No sessions found.');
      return;
    }
    writeLine('  ${'ID'.padRight(14)}  ${'TYPE'.padRight(10)}  ${'PROVIDER'.padRight(10)}  UPDATED');
    for (final raw in sessions) {
      final session = Map<String, dynamic>.from(raw as Map);
      final id = truncate(session['id']?.toString() ?? '', 14).padRight(14);
      final type = (session['type']?.toString() ?? '').padRight(10);
      final provider = (session['provider']?.toString() ?? '—').padRight(10);
      writeLine('  $id  $type  $provider  ${formatDateTime(session['updatedAt'])}');
    }
  });
}
