import '../connected_command_support.dart';

class TracesShowCommand extends ConnectedCommand {
  TracesShowCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a single trace';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final traceId = requirePositionalArg('Trace ID required');
    final trace = await apiClient.getObject('/api/traces/$traceId');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, trace);
      return;
    }
    for (final entry in trace.entries) {
      writeLine('${entry.key}: ${entry.value}');
    }
  });
}
