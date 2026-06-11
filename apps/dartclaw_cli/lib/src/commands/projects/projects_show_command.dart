import '../connected_command_support.dart';

class ProjectsShowCommand extends ConnectedCommand {
  ProjectsShowCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show a project';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final projectId = requirePositionalArg('Project ID required');
    final project = await apiClient.getObject('/api/projects/$projectId');
    final status = await apiClient.getObject('/api/projects/$projectId/status');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, {'project': project, 'status': status});
      return;
    }
    writeLine('Project:      ${project['id']}');
    writeLine('  Name:       ${project['name']}');
    writeLine('  Remote:     ${project['remoteUrl']}');
    writeLine('  Branch:     ${project['defaultBranch']}');
    writeLine('  Status:     ${status['status']}');
    writeLine('  Clone:      ${status['cloneExists'] == true ? 'present' : 'missing'}');
    writeLine('  Last fetch: ${formatDateTime(status['lastFetchAt'])}');
    final auth = status['auth'];
    if (auth is Map<String, dynamic>) {
      writeLine('  Auth:       ${auth['compatible'] == true ? 'ready' : 'error'}');
      if (auth['repository'] != null) {
        writeLine('  Repo:       ${auth['repository']}');
      }
      if (auth['credentialsRef'] != null) {
        writeLine('  Credential: ${auth['credentialsRef']}');
      }
      if (auth['errorMessage'] != null) {
        writeLine('  Auth error: ${auth['errorMessage']}');
      }
    }
    if (status['errorMessage'] != null) {
      writeLine('  Error:      ${status['errorMessage']}');
    }
  });
}
