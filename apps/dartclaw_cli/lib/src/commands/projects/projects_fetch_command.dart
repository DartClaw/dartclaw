import '../connected_command_support.dart';

class ProjectsFetchCommand extends ConnectedCommand {
  ProjectsFetchCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'fetch';

  @override
  String get description => 'Fetch a project from its remote';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final projectId = requirePositionalArg('Project ID required');
    final project = await apiClient.postObject('/api/projects/$projectId/fetch');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, project);
    } else {
      writeLine('Fetched project ${project['id']} (${project['status']}).');
    }
  });
}
