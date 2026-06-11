import '../connected_command_support.dart';

class AgentsShowCommand extends ConnectedCommand {
  AgentsShowCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a single runner';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final runnerId = requirePositionalArg('Runner ID required');
    final runner = await apiClient.getObject('/api/agents/$runnerId');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, runner);
      return;
    }
    for (final entry in runner.entries) {
      writeLine('${entry.key}: ${entry.value}');
    }
  });
}
