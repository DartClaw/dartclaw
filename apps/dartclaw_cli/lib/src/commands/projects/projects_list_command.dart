import '../connected_command_support.dart';

class ProjectsListCommand extends ConnectedCommand {
  ProjectsListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List projects';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final projects = await apiClient.getList('/api/projects');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, projects);
      return;
    }
    if (projects.isEmpty) {
      writeLine('No projects found.');
      return;
    }
    writeLine(
      '  ${'ID'.padRight(16)}  ${'NAME'.padRight(18)}  ${'REMOTE'.padRight(28)}  ${'BRANCH'.padRight(12)}  STATUS',
    );
    for (final raw in projects) {
      final project = Map<String, dynamic>.from(raw as Map);
      final id = truncate(project['id']?.toString() ?? '', 16).padRight(16);
      final name = truncate(project['name']?.toString() ?? '', 18).padRight(18);
      final remote = truncate(project['remoteUrl']?.toString() ?? '', 28).padRight(28);
      final branch = (project['defaultBranch']?.toString() ?? '').padRight(12);
      final status = project['status']?.toString() ?? 'unknown';
      writeLine('  $id  $name  $remote  $branch  $status');
    }
  });
}
