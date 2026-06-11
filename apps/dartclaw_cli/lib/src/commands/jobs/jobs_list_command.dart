import '../connected_command_support.dart';

class JobsListCommand extends ConnectedCommand {
  JobsListCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List scheduled jobs';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final jobs = await apiClient.getList('/api/scheduling/jobs');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, jobs);
      return;
    }
    if (jobs.isEmpty) {
      writeLine('No scheduled jobs found.');
      return;
    }
    writeLine('  ${'NAME'.padRight(20)}  ${'SCHEDULE'.padRight(16)}  TYPE');
    for (final raw in jobs) {
      final job = Map<String, dynamic>.from(raw as Map);
      writeLine(
        '  ${truncate(job['name']?.toString() ?? '', 20).padRight(20)}  '
        '${truncate(job['schedule']?.toString() ?? '', 16).padRight(16)}  '
        '${job['type']}',
      );
    }
  });
}
