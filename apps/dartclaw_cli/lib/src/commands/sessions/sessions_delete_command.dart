import '../connected_command_support.dart';

class SessionsDeleteCommand extends ConnectedCommand {
  SessionsDeleteCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a session';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final sessionId = requirePositionalArg('Session ID required');
    final result = await apiClient.delete('/api/sessions/$sessionId');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, result);
    } else {
      writeLine('Deleted session $sessionId.');
    }
  });
}
