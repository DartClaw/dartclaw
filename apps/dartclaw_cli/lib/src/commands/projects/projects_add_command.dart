import 'package:args/command_runner.dart';

import '../connected_command_support.dart';

class ProjectsAddCommand extends ConnectedCommand {
  ProjectsAddCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('name', help: 'Project name')
      ..addOption('remote-url', help: 'Remote Git URL')
      ..addOption('branch', help: 'Default branch', defaultsTo: 'main')
      ..addOption('credentials-ref', help: 'Optional credentials reference')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Add a project';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final name = (argResults!['name'] as String?)?.trim();
    final remoteUrl = (argResults!['remote-url'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      throw UsageException('--name is required', usage);
    }
    if (remoteUrl == null || remoteUrl.isEmpty) {
      throw UsageException('--remote-url is required', usage);
    }

    final project = await apiClient.postObject(
      '/api/projects',
      body: {
        'name': name,
        'remoteUrl': remoteUrl,
        'defaultBranch': (argResults!['branch'] as String?)?.trim() ?? 'main',
        if ((argResults!['credentials-ref'] as String?)?.trim().isNotEmpty == true)
          'credentialsRef': (argResults!['credentials-ref'] as String).trim(),
      },
    );
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, project);
    } else {
      writeLine('Added project ${project['id']} (${project['status']}).');
    }
  });
}
