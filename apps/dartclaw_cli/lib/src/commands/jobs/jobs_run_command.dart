import '../connected_command_support.dart';

class JobsRunCommand extends ConnectedCommand {
  new({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run a scheduled job immediately';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final jobName = requirePositionalArg('Job name required');
    final encodedName = Uri.encodeComponent(jobName);
    final result = await apiClient.postObject('/api/scheduling/jobs/$encodedName/run');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, result);
    } else {
      writeLine('Job $jobName started. Observe its configured delivery (if any) and server logs for the outcome.');
    }
  });
}
