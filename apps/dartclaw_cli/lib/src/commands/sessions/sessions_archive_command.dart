import '../connected_command_support.dart';

class SessionsArchiveCommand extends ConnectedCommand {
  SessionsArchiveCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'archive';

  @override
  String get description => 'Archive a session';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final sessionId = requirePositionalArg('Session ID required');
    final session = await apiClient.postObject('/api/sessions/$sessionId/archive');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, session);
    } else {
      writeLine('Archived session ${session['id']} (${session['type']}).');
    }
  });
}
