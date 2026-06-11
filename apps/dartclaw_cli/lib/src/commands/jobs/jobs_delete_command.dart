import '../connected_command_support.dart';

class JobsDeleteCommand extends ConnectedCommand {
  JobsDeleteCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a scheduled job';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final jobName = requirePositionalArg('Job name required');
    final result = await apiClient.deleteObject('/api/scheduling/jobs/$jobName');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, result);
    } else {
      writeLine('Deleted job $jobName. Restart the server to apply scheduling changes.');
    }
  });
}
