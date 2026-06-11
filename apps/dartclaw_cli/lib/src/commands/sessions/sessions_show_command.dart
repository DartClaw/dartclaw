import '../connected_command_support.dart';

class SessionsShowCommand extends ConnectedCommand {
  SessionsShowCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a session';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final sessionId = requirePositionalArg('Session ID required');
    final session = await apiClient.getObject('/api/sessions/$sessionId');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, session);
      return;
    }
    writeLine('Session:      ${session['id']}');
    writeLine('  Type:       ${session['type']}');
    writeLine('  Provider:   ${session['provider'] ?? '—'}');
    writeLine('  Channel key:${session['channelKey'] ?? '—'}');
    writeLine('  Title:      ${session['title'] ?? '—'}');
    writeLine('  Created:    ${formatDateTime(session['createdAt'])}');
    writeLine('  Updated:    ${formatDateTime(session['updatedAt'])}');
  });
}
