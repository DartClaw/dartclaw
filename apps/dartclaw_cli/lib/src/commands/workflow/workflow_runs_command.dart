import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show formatLocalDateTime, truncate;

import '../connected_command_support.dart' hide truncate;

class WorkflowRunsCommand extends ConnectedCommand {
  WorkflowRunsCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('status', help: 'Filter by workflow status')
      ..addOption('definition', help: 'Filter by workflow definition name')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'runs';

  @override
  String get description => 'List recent workflow runs from the server';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final runs = await apiClient.getList(
      '/api/workflows/runs',
      queryParameters: {'status': argResults!['status'] as String?, 'definition': argResults!['definition'] as String?},
    );
    if (argResults!['json'] as bool) {
      writeLine(const JsonEncoder.withIndent('  ').convert(runs));
      return;
    }
    _printTable(runs);
  });

  void _printTable(List<dynamic> runs) {
    if (runs.isEmpty) {
      writeLine('No workflow runs found.');
      return;
    }
    writeLine('  ${'ID'.padRight(12)}  ${'DEFINITION'.padRight(24)}  ${'STATUS'.padRight(10)}  STARTED');
    for (final raw in runs) {
      final run = Map<String, dynamic>.from(raw as Map);
      final id = truncate(run['id']?.toString() ?? '', 12, suffix: '...').padRight(12);
      final definition = truncate(run['definitionName']?.toString() ?? '', 24, suffix: '...').padRight(24);
      final status = (run['status']?.toString() ?? '').padRight(10);
      final started = formatLocalDateTime(run['startedAt']?.toString());
      writeLine('  $id  $definition  $status  $started');
    }
  }
}
