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
    writeLine('  ${'ID'.padRight(20)}  ${'SCHEDULE'.padRight(16)}  TYPE');
    for (final raw in jobs) {
      final job = Map<String, dynamic>.from(raw as Map);
      final id = (job['id'] ?? job['name'])?.toString() ?? '';
      final schedule = _formatSchedule(job['schedule']);
      final type = job['type']?.toString() ?? 'prompt';
      writeLine(
        '  ${truncate(id, 20).padRight(20)}  '
        '${truncate(schedule, 16).padRight(16)}  '
        '$type',
      );
    }
  });
}

String _formatSchedule(Object? raw) {
  const invalid = '<invalid>';
  if (raw is String) return raw.trim().isEmpty ? invalid : raw.trim();
  if (raw is! Map) return invalid;

  final schedule = Map<Object?, Object?>.from(raw);
  switch (schedule['type']) {
    case 'cron':
      final expression = schedule['expression'];
      return expression is String && expression.trim().isNotEmpty ? expression.trim() : invalid;
    case 'interval':
      final minutes = schedule['minutes'];
      return minutes is int && minutes > 0 ? 'every $minutes minutes' : invalid;
    case 'once':
      final at = schedule['at'];
      return at is String && DateTime.tryParse(at) != null ? at : invalid;
    default:
      return invalid;
  }
}
