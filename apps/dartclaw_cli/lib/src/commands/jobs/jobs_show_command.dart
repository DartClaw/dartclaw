import '../connected_command_support.dart';

class JobsShowCommand extends ConnectedCommand {
  JobsShowCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a scheduled job';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final jobName = requirePositionalArg('Job name required');
    final job = await apiClient.getObject('/api/scheduling/jobs/$jobName');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, job);
      return;
    }
    for (final entry in job.entries) {
      writeLine('${entry.key}: ${entry.value}');
    }
  });
}
