import '../connected_command_support.dart';

class JobsShowCommand extends ConnectedCommand {
  new({super.config, super.apiClient, super.writeLine, super.exitFn}) {
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
    final lifecycle = job['lifecycle'];
    final index = job['index'];
    for (final entry in job.entries.where((entry) => entry.key != 'lifecycle' && entry.key != 'index')) {
      writeLine('${entry.key}: ${_safe(entry.value)}');
    }
    if (lifecycle is Map) {
      writeLine('lifecycle: ${_safe(lifecycle['state'])}');
      for (final key in [
        'startedAt',
        'completedAt',
        'lastSuccessAt',
        'snapshotRevision',
        'currentRevision',
        'committedRevision',
      ]) {
        if (lifecycle[key] != null) writeLine('$key: ${_safe(lifecycle[key])}');
      }
      for (final key in ['changedIds', 'noOpIds']) {
        if (lifecycle[key] is List) writeLine('$key: ${(lifecycle[key] as List).map(_safe).join(', ')}');
      }
      final operationReasons = lifecycle['operationReasons'];
      if (operationReasons is Map) {
        for (final entry in operationReasons.entries) {
          writeLine('operationReason ${_safe(entry.key)}: ${_safe(entry.value)}');
        }
      }
      final reason = lifecycle['failureReason'] ?? lifecycle['reason'];
      if (reason != null) writeLine('reason: ${_safe(reason)}');
      if (lifecycle['action'] != null) writeLine('action: ${_safe(lifecycle['action'])}');
    }
    if (index is Map) {
      writeLine('index: ${_safe(index['state'])}');
      if (index['action'] != null) writeLine('indexAction: ${_safe(index['action'])}');
    }
  });
}

String _safe(Object? value) =>
    truncate((value?.toString() ?? 'null').replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' '), 500);
