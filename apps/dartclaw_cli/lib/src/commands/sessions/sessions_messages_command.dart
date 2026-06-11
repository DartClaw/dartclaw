import '../connected_command_support.dart';

class SessionsMessagesCommand extends ConnectedCommand {
  SessionsMessagesCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('limit', help: 'Maximum number of messages to show')
      ..addFlag('full', negatable: false, help: 'Print full message content')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'messages';

  @override
  String get description => 'Show session messages';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final sessionId = requirePositionalArg('Session ID required');
    final messages = await apiClient.getList('/api/sessions/$sessionId/messages');
    final limit = int.tryParse((argResults!['limit'] as String?) ?? '');
    final visible = limit == null || limit >= messages.length ? messages : messages.take(limit).toList(growable: false);
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, visible);
      return;
    }
    final full = argResults!['full'] as bool;
    for (final raw in visible) {
      final message = Map<String, dynamic>.from(raw as Map);
      final role = (message['role']?.toString() ?? 'unknown').padRight(10);
      final content = message['content']?.toString() ?? '';
      writeLine('$role ${full ? content : truncate(content, 100)}');
    }
  });
}
